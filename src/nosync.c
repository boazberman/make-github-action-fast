/*
 * make-github-action-fast - libnosync
 * Intercepts fsync / sync / syncfs / msync / sync_file_range and strips O_SYNC / O_DSYNC from open / openat.
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
#include <stdlib.h>
#include <errno.h>
#include <sys/types.h>

#ifndef O_SYNC
#define O_SYNC 04010000
#endif
#ifndef O_DSYNC
#define O_DSYNC 00010000
#endif

static int g_passthrough = 0;

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
        flags &= ~(O_SYNC | O_DSYNC);
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
        flags &= ~(O_SYNC | O_DSYNC);
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
        flags &= ~(O_SYNC | O_DSYNC);
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
        flags &= ~(O_SYNC | O_DSYNC);
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
        flags &= ~(O_SYNC | O_DSYNC);
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
        flags &= ~(O_SYNC | O_DSYNC);
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
        flags &= ~(O_SYNC | O_DSYNC);
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
        flags &= ~(O_SYNC | O_DSYNC);
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
