/*
 * overclock - libnosync
 * Intercepts fsync / sync / syncfs / msync / sync_file_range and strips O_SYNC / O_DSYNC from open / openat and RWF_SYNC / RWF_DSYNC from pwritev2.
 */

#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#undef _FORTIFY_SOURCE

#include <dlfcn.h>
#include <fcntl.h>
#include <stdarg.h>
#include <unistd.h>
#include <sys/mman.h>
#include <sys/auxv.h>
#include <sys/uio.h>
#include <stdlib.h>
#include <stdio.h>
#include <errno.h>
#include <pthread.h>
#include <sys/types.h>

#ifndef O_SYNC
#define O_SYNC 04010000
#endif
#ifndef O_DSYNC
#define O_DSYNC 00010000
#endif
#ifndef RWF_DSYNC
#define RWF_DSYNC 0x00000002
#endif
#ifndef RWF_SYNC
#define RWF_SYNC 0x00000004
#endif

static int g_passthrough = 0;
static unsigned long g_skipped_sync = 0;
static unsigned long g_stripped_osync = 0;

static int (*real_fsync)(int) = NULL;
static int (*real_fdatasync)(int) = NULL;
static void (*real_sync)(void) = NULL;
static int (*real_syncfs)(int) = NULL;
static int (*real_msync)(void *, size_t, int) = NULL;
static int (*real_sync_file_range)(int, off64_t, off64_t, unsigned int) = NULL;
static int (*real_open)(const char *, int, ...) = NULL;
static int (*real_open64)(const char *, int, ...) = NULL;
static int (*real_openat)(int, const char *, int, ...) = NULL;
static int (*real_openat64)(int, const char *, int, ...) = NULL;
static ssize_t (*real_pwritev2)(int, const struct iovec *, int, off_t, int) = NULL;
static ssize_t (*real_pwritev64v2)(int, const struct iovec *, int, off64_t, int) = NULL;

static void init_real_symbols(void) {
    real_fsync = (int (*)(int))dlsym(RTLD_NEXT, "fsync");
    real_fdatasync = (int (*)(int))dlsym(RTLD_NEXT, "fdatasync");
    real_sync = (void (*)(void))dlsym(RTLD_NEXT, "sync");
    real_syncfs = (int (*)(int))dlsym(RTLD_NEXT, "syncfs");
    real_msync = (int (*)(void *, size_t, int))dlsym(RTLD_NEXT, "msync");
    real_sync_file_range = (int (*)(int, off64_t, off64_t, unsigned int))dlsym(RTLD_NEXT, "sync_file_range");
    real_open = (int (*)(const char *, int, ...))dlsym(RTLD_NEXT, "open");
    real_open64 = (int (*)(const char *, int, ...))dlsym(RTLD_NEXT, "open64");
    real_openat = (int (*)(int, const char *, int, ...))dlsym(RTLD_NEXT, "openat");
    real_openat64 = (int (*)(int, const char *, int, ...))dlsym(RTLD_NEXT, "openat64");
    real_pwritev2 = (ssize_t (*)(int, const struct iovec *, int, off_t, int))dlsym(RTLD_NEXT, "pwritev2");
    real_pwritev64v2 = (ssize_t (*)(int, const struct iovec *, int, off64_t, int))dlsym(RTLD_NEXT, "pwritev64v2");
}

static void reset_counters(void) {
    __atomic_store_n(&g_skipped_sync, 0, __ATOMIC_RELAXED);
    __atomic_store_n(&g_stripped_osync, 0, __ATOMIC_RELAXED);
}

__attribute__((constructor))
static void nosync_init(void) {
    if (getauxval(AT_SECURE) != 0) {
        g_passthrough = 1;
    } else {
        const char *env = getenv("NOSYNC_DISABLE");
        if (env && env[0] != '\0' && (env[0] != '0' || env[1] != '\0')) {
            g_passthrough = 1;
        }
    }
    init_real_symbols();
    pthread_atfork(NULL, NULL, reset_counters);
}

__attribute__((destructor))
static void nosync_fini(void) {
    if (g_passthrough) {
        return;
    }
    if (getauxval(AT_SECURE) != 0) {
        return;
    }
    unsigned long s_sync = __atomic_load_n(&g_skipped_sync, __ATOMIC_RELAXED);
    unsigned long s_osync = __atomic_load_n(&g_stripped_osync, __ATOMIC_RELAXED);
    if (s_sync == 0 && s_osync == 0) {
        return;
    }
    const char *stats_file = getenv("NOSYNC_STATS_FILE");
    if (!stats_file || stats_file[0] == '\0') {
        return;
    }
    if (!real_open) {
        real_open = (int (*)(const char *, int, ...))dlsym(RTLD_NEXT, "open");
    }
    if (!real_open) {
        return;
    }
    int fd = real_open(stats_file, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0666);
    if (fd < 0) {
        return;
    }
    char buf[128];
    int len = snprintf(buf, sizeof(buf), "%ld %lu %lu\n", (long)getpid(), s_sync, s_osync);
    if (len > 0) {
        ssize_t ret = write(fd, buf, (size_t)len);
        (void)ret;
    }
    close(fd);
}

static inline int flags_require_mode(int flags) {
#ifdef O_TMPFILE
    if ((flags & O_TMPFILE) == O_TMPFILE) {
        return 1;
    }
#endif
    return (flags & O_CREAT) != 0;
}

int fsync(int fd) {
    if (!g_passthrough) {
        __atomic_fetch_add(&g_skipped_sync, 1, __ATOMIC_RELAXED);
        return 0;
    }
    if (!real_fsync) {
        real_fsync = (int (*)(int))dlsym(RTLD_NEXT, "fsync");
    }
    if (real_fsync) {
        return real_fsync(fd);
    }
    return 0;
}

int fdatasync(int fd) {
    if (!g_passthrough) {
        __atomic_fetch_add(&g_skipped_sync, 1, __ATOMIC_RELAXED);
        return 0;
    }
    if (!real_fdatasync) {
        real_fdatasync = (int (*)(int))dlsym(RTLD_NEXT, "fdatasync");
    }
    if (real_fdatasync) {
        return real_fdatasync(fd);
    }
    return 0;
}

void sync(void) {
    if (!g_passthrough) {
        __atomic_fetch_add(&g_skipped_sync, 1, __ATOMIC_RELAXED);
        return;
    }
    if (!real_sync) {
        real_sync = (void (*)(void))dlsym(RTLD_NEXT, "sync");
    }
    if (real_sync) {
        real_sync();
    }
}

int syncfs(int fd) {
    if (!g_passthrough) {
        __atomic_fetch_add(&g_skipped_sync, 1, __ATOMIC_RELAXED);
        return 0;
    }
    if (!real_syncfs) {
        real_syncfs = (int (*)(int))dlsym(RTLD_NEXT, "syncfs");
    }
    if (real_syncfs) {
        return real_syncfs(fd);
    }
    return 0;
}

int msync(void *addr, size_t length, int flags) {
    if (!g_passthrough) {
        __atomic_fetch_add(&g_skipped_sync, 1, __ATOMIC_RELAXED);
        return 0;
    }
    if (!real_msync) {
        real_msync = (int (*)(void *, size_t, int))dlsym(RTLD_NEXT, "msync");
    }
    if (real_msync) {
        return real_msync(addr, length, flags);
    }
    return 0;
}

int sync_file_range(int fd, off64_t offset, off64_t nbytes, unsigned int flags) {
    if (!g_passthrough) {
        __atomic_fetch_add(&g_skipped_sync, 1, __ATOMIC_RELAXED);
        return 0;
    }
    if (!real_sync_file_range) {
        real_sync_file_range = (int (*)(int, off64_t, off64_t, unsigned int))dlsym(RTLD_NEXT, "sync_file_range");
    }
    if (real_sync_file_range) {
        return real_sync_file_range(fd, offset, nbytes, flags);
    }
    return 0;
}

int open(const char *pathname, int flags, ...) {
    mode_t mode = 0;
    if (flags_require_mode(flags)) {
        va_list ap;
        va_start(ap, flags);
        mode = (mode_t)va_arg(ap, int);
        va_end(ap);
    }

    if (!g_passthrough) {
        if ((flags & (O_SYNC | O_DSYNC)) != 0) {
            flags &= ~(O_SYNC | O_DSYNC);
            __atomic_fetch_add(&g_stripped_osync, 1, __ATOMIC_RELAXED);
        }
    }

    if (!real_open) {
        real_open = (int (*)(const char *, int, ...))dlsym(RTLD_NEXT, "open");
    }
    if (!real_open) {
        errno = ENOSYS;
        return -1;
    }
    return real_open(pathname, flags, mode);
}

int open64(const char *pathname, int flags, ...) {
    mode_t mode = 0;
    if (flags_require_mode(flags)) {
        va_list ap;
        va_start(ap, flags);
        mode = (mode_t)va_arg(ap, int);
        va_end(ap);
    }

    if (!g_passthrough) {
        if ((flags & (O_SYNC | O_DSYNC)) != 0) {
            flags &= ~(O_SYNC | O_DSYNC);
            __atomic_fetch_add(&g_stripped_osync, 1, __ATOMIC_RELAXED);
        }
    }

    if (!real_open64) {
        real_open64 = (int (*)(const char *, int, ...))dlsym(RTLD_NEXT, "open64");
    }
    if (!real_open64) {
        if (!real_open) {
            real_open = (int (*)(const char *, int, ...))dlsym(RTLD_NEXT, "open");
        }
        if (real_open) {
            return real_open(pathname, flags, mode);
        }
        errno = ENOSYS;
        return -1;
    }
    return real_open64(pathname, flags, mode);
}

int openat(int dirfd, const char *pathname, int flags, ...) {
    mode_t mode = 0;
    if (flags_require_mode(flags)) {
        va_list ap;
        va_start(ap, flags);
        mode = (mode_t)va_arg(ap, int);
        va_end(ap);
    }

    if (!g_passthrough) {
        if ((flags & (O_SYNC | O_DSYNC)) != 0) {
            flags &= ~(O_SYNC | O_DSYNC);
            __atomic_fetch_add(&g_stripped_osync, 1, __ATOMIC_RELAXED);
        }
    }

    if (!real_openat) {
        real_openat = (int (*)(int, const char *, int, ...))dlsym(RTLD_NEXT, "openat");
    }
    if (!real_openat) {
        errno = ENOSYS;
        return -1;
    }
    return real_openat(dirfd, pathname, flags, mode);
}

int openat64(int dirfd, const char *pathname, int flags, ...) {
    mode_t mode = 0;
    if (flags_require_mode(flags)) {
        va_list ap;
        va_start(ap, flags);
        mode = (mode_t)va_arg(ap, int);
        va_end(ap);
    }

    if (!g_passthrough) {
        if ((flags & (O_SYNC | O_DSYNC)) != 0) {
            flags &= ~(O_SYNC | O_DSYNC);
            __atomic_fetch_add(&g_stripped_osync, 1, __ATOMIC_RELAXED);
        }
    }

    if (!real_openat64) {
        real_openat64 = (int (*)(int, const char *, int, ...))dlsym(RTLD_NEXT, "openat64");
    }
    if (!real_openat64) {
        if (!real_openat) {
            real_openat = (int (*)(int, const char *, int, ...))dlsym(RTLD_NEXT, "openat");
        }
        if (real_openat) {
            return real_openat(dirfd, pathname, flags, mode);
        }
        errno = ENOSYS;
        return -1;
    }
    return real_openat64(dirfd, pathname, flags, mode);
}

int __open_2(const char *pathname, int flags) {
    if (!g_passthrough) {
        if ((flags & (O_SYNC | O_DSYNC)) != 0) {
            flags &= ~(O_SYNC | O_DSYNC);
            __atomic_fetch_add(&g_stripped_osync, 1, __ATOMIC_RELAXED);
        }
    }
    if (!real_open) {
        real_open = (int (*)(const char *, int, ...))dlsym(RTLD_NEXT, "open");
    }
    if (!real_open) {
        errno = ENOSYS;
        return -1;
    }
    return real_open(pathname, flags, 0);
}

int __open64_2(const char *pathname, int flags) {
    if (!g_passthrough) {
        if ((flags & (O_SYNC | O_DSYNC)) != 0) {
            flags &= ~(O_SYNC | O_DSYNC);
            __atomic_fetch_add(&g_stripped_osync, 1, __ATOMIC_RELAXED);
        }
    }
    if (!real_open64) {
        real_open64 = (int (*)(const char *, int, ...))dlsym(RTLD_NEXT, "open64");
    }
    if (!real_open64) {
        if (!real_open) {
            real_open = (int (*)(const char *, int, ...))dlsym(RTLD_NEXT, "open");
        }
        if (real_open) {
            return real_open(pathname, flags, 0);
        }
        errno = ENOSYS;
        return -1;
    }
    return real_open64(pathname, flags, 0);
}

int __openat_2(int dirfd, const char *pathname, int flags) {
    if (!g_passthrough) {
        if ((flags & (O_SYNC | O_DSYNC)) != 0) {
            flags &= ~(O_SYNC | O_DSYNC);
            __atomic_fetch_add(&g_stripped_osync, 1, __ATOMIC_RELAXED);
        }
    }
    if (!real_openat) {
        real_openat = (int (*)(int, const char *, int, ...))dlsym(RTLD_NEXT, "openat");
    }
    if (!real_openat) {
        errno = ENOSYS;
        return -1;
    }
    return real_openat(dirfd, pathname, flags, 0);
}

int __openat64_2(int dirfd, const char *pathname, int flags) {
    if (!g_passthrough) {
        if ((flags & (O_SYNC | O_DSYNC)) != 0) {
            flags &= ~(O_SYNC | O_DSYNC);
            __atomic_fetch_add(&g_stripped_osync, 1, __ATOMIC_RELAXED);
        }
    }
    if (!real_openat64) {
        real_openat64 = (int (*)(int, const char *, int, ...))dlsym(RTLD_NEXT, "openat64");
    }
    if (!real_openat64) {
        if (!real_openat) {
            real_openat = (int (*)(int, const char *, int, ...))dlsym(RTLD_NEXT, "openat");
        }
        if (real_openat) {
            return real_openat(dirfd, pathname, flags, 0);
        }
        errno = ENOSYS;
        return -1;
    }
    return real_openat64(dirfd, pathname, flags, 0);
}

ssize_t pwritev2(int fd, const struct iovec *iov, int iovcnt, off_t offset, int flags) {
    if (!g_passthrough) {
        if ((flags & (RWF_SYNC | RWF_DSYNC)) != 0) {
            flags &= ~(RWF_SYNC | RWF_DSYNC);
            __atomic_fetch_add(&g_stripped_osync, 1, __ATOMIC_RELAXED);
        }
    }
    if (!real_pwritev2) {
        real_pwritev2 = (ssize_t (*)(int, const struct iovec *, int, off_t, int))dlsym(RTLD_NEXT, "pwritev2");
    }
    if (real_pwritev2) {
        return real_pwritev2(fd, iov, iovcnt, offset, flags);
    }
    errno = ENOSYS;
    return -1;
}

ssize_t pwritev64v2(int fd, const struct iovec *iov, int iovcnt, off64_t offset, int flags) {
    if (!g_passthrough) {
        if ((flags & (RWF_SYNC | RWF_DSYNC)) != 0) {
            flags &= ~(RWF_SYNC | RWF_DSYNC);
            __atomic_fetch_add(&g_stripped_osync, 1, __ATOMIC_RELAXED);
        }
    }
    if (!real_pwritev64v2) {
        real_pwritev64v2 = (ssize_t (*)(int, const struct iovec *, int, off64_t, int))dlsym(RTLD_NEXT, "pwritev64v2");
    }
    if (!real_pwritev64v2) {
        if (!real_pwritev2) {
            real_pwritev2 = (ssize_t (*)(int, const struct iovec *, int, off_t, int))dlsym(RTLD_NEXT, "pwritev2");
        }
        if (real_pwritev2) {
            return real_pwritev2(fd, iov, iovcnt, (off_t)offset, flags);
        }
        errno = ENOSYS;
        return -1;
    }
    return real_pwritev64v2(fd, iov, iovcnt, offset, flags);
}
