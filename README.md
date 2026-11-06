# overclock

A lightweight, zero-dependency GitHub Action that accelerates Linux CI workflows by eliminating disk I/O bottlenecks. In ephemeral CI runners, disk durability guarantees—such as synchronous writes, ext4 journal barriers, and frequent dirty page flushes—introduce latency without providing reliability benefits, since the runner VM is discarded immediately after the job finishes. The large, measured win is for fsync-heavy workloads such as SQLite or embedded-database test suites (7–16× on a synthetic commit benchmark; see [Benchmarks](#benchmarks)). Everything else, including `apt`, `npm ci`, `pip install` and `cargo build`, measured within noise (0.97–1.03×) on GitHub-hosted runners, because syncs there are cheap and these tools are mostly CPU- or network-bound. If your job doesn't do lots of synchronous database commits, don't expect a visible speedup. Setup typically takes 300–400 ms, compiling an fsync-interposition library on the fly with no third-party npm dependencies. `overclock` adheres strictly to a zero-failure rule: if any privileged kernel or mount operation is restricted (such as in unprivileged containers or restricted self-hosted environments), it logs a warning and degrades gracefully without failing your build.

---

## Quick Start

Place `overclock` as the first step in your job, before `actions/checkout@v5`. This ensures kernel page-cache sysctls, filesystem remounts, Git environment configurations, and `LD_PRELOAD` interpositions are active before checking out repository files or installing dependencies:

```yaml
jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - name: Accelerate runner
        uses: boazberman/overclock@v2

      - name: Checkout code
        uses: actions/checkout@v5

      - name: Test
        run: npm test
```

---

## Inputs & Outputs

### Inputs

| Input | Description | Default |
|---|---|---|
| `fsync-bypass` | Compile and enable `libnosync.so` via `LD_PRELOAD` to no-op `fsync`, `fdatasync`, `sync`, `syncfs`, `msync`, `sync_file_range`, and strip `O_SYNC`/`O_DSYNC`/`RWF_SYNC`/`RWF_DSYNC` flags. | `'true'` |
| `preload-scope` | Preload scope: `'env'` exports `LD_PRELOAD` to `GITHUB_ENV` for runner steps. `'global'` additionally appends the library to `/etc/ld.so.preload` (covering `sudo` and background daemons; root only). | `'env'` |
| `page-cache-tuning` | Apply moderate Linux kernel dirty page cache writeback sysctls (`dirty_ratio=45`, `dirty_background_ratio=15`, `swappiness=10` or `100`, `vfs_cache_pressure=50`). | `'true'` |
| `remount-fast` | Remount ext4 filesystems (`/` and `/mnt`) with `noatime,barrier=0,commit=60`. Skipped on self-hosted runners unless `self-hosted-unsafe` is enabled. | `'true'` |
| `git-tuning` | Export non-persistent Git optimization settings via environment variables (`GIT_CONFIG_*`). Requires Git &ge; 2.31. | `'true'` |
| `apt-tuning` | Configure `dpkg` `force-unsafe-io`, set apt `Acquire::Languages "none"`, remove `/var/lib/man-db/auto-update`, and stop background apt systemd timers. | `'true'` |
| `build-env` | Opt-in build environment tuning: sets `MAKEFLAGS`, `CMAKE_BUILD_PARALLEL_LEVEL`, `CARGO_INCREMENTAL=0`, `CARGO_NET_GIT_FETCH_WITH_CLI=true`, and `MALLOC_ARENA_MAX` based on CPU core count (only if unset). | `'false'` |
| `zram-swap` | Allocate a compressed in-memory RAM block device as swap space to expand memory headroom and prevent runner OOM kills. | `'false'` |
| `zram-swap-size` | Size of the zram swap device: percentage of `MemTotal` (e.g. `'50%'`) or absolute byte size (e.g. `'4G'`, `'512M'`). | `'50%'` |
| `tmpfs-paths` | Comma-separated list of absolute directories (leading `~/` expands to runner home) to mount in-memory `tmpfs` over, copying existing files into RAM. | `''` |
| `tmpfs-size` | Mount size option for tmpfs volumes (percentage or absolute, e.g. `'50%'` or `'4G'`). | `'50%'` |
| `self-hosted-unsafe` | On self-hosted runners: permit ext4 remounting, system library installation to `/usr/lib`, and setuid binary copies. | `'false'` |
| `summary` | Emit an optimization summary, fsync bypass metrics, and system I/O telemetry table to `$GITHUB_STEP_SUMMARY`. | `'true'` |
| `zram-workspace` | **DEPRECATED**: Legacy alias for `zram-swap`. Logs a warning and activates `zram-swap`. | `''` |
| `zram-size` | **DEPRECATED**: Legacy alias for `zram-swap-size`. | `''` |
| `spill-dirs` | **DEPRECATED**: Ignored with a warning if specified. | `''` |

### Outputs

| Output | Description | Example |
|---|---|---|
| `setup-time-ms` | Total wall-clock time spent during the setup step in milliseconds. | `118` |
| `fsync-bypass` | Final status of the fsync bypass interceptor (`'active'`, `'disabled'`, or `'failed'`). | `active` |
| `zram-device` | Allocated zram block device path (e.g. `'/dev/zram0'`), or empty string if unused. | `/dev/zram0` |
| `profile` | Privilege profile detected for the runner (`'hosted'`, `'self-hosted-safe'`, `'self-hosted-unsafe'`, or `'unprivileged'`). | `hosted` |

---

## Privilege Profiles & Teardown

`overclock` inspects user privileges and runner environment variables (`RUNNER_ENVIRONMENT`) to select an execution profile that balances speed with host safety:

| Profile | Environment | remount-fast | sysctl & apt | zram swap & tmpfs | libnosync Install Path | Preload Scope |
|---|---|---|---|---|---|---|
| `hosted` | GitHub-hosted runner (root / passwordless sudo) | Enabled | Enabled | Enabled | `/usr/lib/<triplet>/libnosync.so` (mode 4755) | `env` (or `global`) |
| `self-hosted-safe` | Self-hosted runner (default, `self-hosted-unsafe: false`) | Skipped | Enabled | Enabled | `$RUNNER_TEMP/overclock/lib/libnosync.so` | `env` only |
| `self-hosted-unsafe` | Self-hosted runner with `self-hosted-unsafe: true` | Enabled | Enabled | Enabled | `/usr/lib/<triplet>/libnosync.so` (mode 4755) | `env` (or `global`) |
| `unprivileged` | Container jobs or non-root users without sudo | Skipped | Skipped | Skipped | `$RUNNER_TEMP/overclock/lib/libnosync.so` | `env` only |

### Self-Hosted Teardown

On ephemeral GitHub-hosted runners, VMs are discarded after the job, so no teardown is necessary. On self-hosted runners (`RUNNER_ENVIRONMENT === 'self-hosted'`), `post.js` runs `setup-linux.sh teardown` at the conclusion of the job to restore the host state:

1. **Kernel sysctls**: Reverts modified `/proc/sys/vm/` and `/proc/sys/fs/` entries to their exact pre-run values recorded in `ORIG_SYSCTL`.
2. **Filesystem remounts**: Reverts altered ext4 mounts back to standard durable flags: `mount -o remount,barrier=1,commit=5,relatime`.
3. **Apt & dpkg**: Deletes `/etc/dpkg/dpkg.cfg.d/overclock-unsafe-io` and `/etc/apt/apt.conf.d/99overclock`, restores `/var/lib/man-db/auto-update` if it originally existed, and restarts stopped apt/unattended-upgrades timers.
4. **Linker configuration**: Restores `/etc/ld.so.preload` from backup (or removes it if it was created by the action).
5. **tmpfs mounts**: Lazily unmounts all configured tmpfs paths (`umount -l`).
6. **zram swap**: Disables swap via `swapoff` and resets the block device via `zramctl --reset`.
7. **System libraries**: Deletes the installed library at `/usr/lib/<triplet>/libnosync.so`.

Teardown is strictly idempotent and designed never to fail or block job completion.

---

## How It Works

### 1. Fsync Bypass (`libnosync.so`)

Package managers, database engines, and compilers call `fsync()` to ensure dirty data is flushed from operating system page cache to physical disk platters or SSD flash. In disposable CI runners, flushing writes to disk is unnecessary overhead.

- **On-the-fly compilation**: Rather than downloading external binary blobs or running package manager updates, `overclock` compiles `src/nosync.c` using the runner's preinstalled `gcc` in **~50–100 ms** in parallel with kernel sysctl initialization.
- **Interposed syscalls**: Intercepts `fsync`, `fdatasync`, `sync`, `syncfs`, `msync`, and `sync_file_range`, returning `0` immediately without issuing blocking I/O calls.
- **Flag stripping**: Intercepts `open`, `open64`, `openat`, `openat64`, and glibc fortified variants (`__open_2`, `__open64_2`, `__openat_2`, `__openat64_2`), clearing `O_SYNC` and `O_DSYNC`. It also wraps `pwritev2` and `pwritev64v2`, stripping `RWF_SYNC` and `RWF_DSYNC`.
- **Preload scopes (`env` vs. `global`)**:
  - `env` (default): Appends `LD_PRELOAD` to `GITHUB_ENV`. Inherited by all subsequent workflow steps running under the runner user.
  - `global`: When running privileged, appends the path to `/etc/ld.so.preload`. This preloads `libnosync.so` into every dynamically linked process spawned across the entire host, including processes launched via `sudo` and background system daemons.
- **Setuid copy rationale & `AT_SECURE`**: The Linux dynamic linker (`ld.so`) disables `LD_PRELOAD` for setuid binaries (such as `sudo`) unless the preload library resides in a trusted system library directory (`/usr/lib/<triplet>/`) and has its setuid bit set. In `hosted` or `self-hosted-unsafe` profiles, `overclock` installs `libnosync.so` to `/usr/lib/$(gcc -dumpmachine)/libnosync.so` with mode `4755`. To maintain system security integrity, the constructor calls `getauxval(AT_SECURE)`: if running under elevated setuid privileges, the library switches to transparent passthrough mode, forwarding calls to real libc functions without bypassing sync operations.
- **Atomic counters & `NOSYNC_STATS_FILE`**: Tracks skipped sync operations and stripped flags using GCC relaxed atomic intrinsics (`__atomic_fetch_add`). To prevent child processes from duplicating parent counters across `fork()`, the library registers a reset handler via `pthread_atfork(NULL, NULL, reset_counters)`. On process termination, the destructor opens `NOSYNC_STATS_FILE` directly via dlsym'd libc `open` and writes `<pid> <skipped_sync> <stripped_osync>\n` in a single atomic write.
- **Runtime bypass (`NOSYNC_DISABLE`)**: If `NOSYNC_DISABLE` is set in the environment to a non-zero string, `libnosync.so` dynamically delegates all calls directly to the underlying libc implementation.
- **AddressSanitizer compatibility (`ASAN_OPTIONS`)**: When fsync bypass is active, `overclock` automatically appends `verify_asan_link_order=0` to `ASAN_OPTIONS` in `GITHUB_ENV`. This prevents ASan runtime crashes caused by AddressSanitizer requiring its runtime library to appear first in `LD_PRELOAD`.

### 2. Page Cache Sysctl Tuning

Linux kernel defaults are tuned for long-running servers that must minimize data loss during power failures. Ephemeral CI runners have ample RAM (7–16 GB on standard GitHub-hosted runners) and are terminated upon job completion.

The action tunes parameters via direct writes to `/proc/sys/vm/` and `/proc/sys/fs/`:

| Parameter | Default Value | Tuned Value | Rationale |
|---|---|---|---|
| `vm.dirty_ratio` | `20%` | `45%` | Percentage of total memory that can hold dirty pages before processes stall to flush. Written before `dirty_background_ratio` to avoid ratio clamping. |
| `vm.dirty_background_ratio` | `10%` | `15%` | Memory threshold where background kernel flusher threads begin writing dirty pages out to disk. |
| `vm.dirty_expire_centisecs` | `3000` (30 s) | `3000` (30 s) | Maximum age of dirty data before it must be queued for writeback. |
| `vm.dirty_writeback_centisecs` | `500` (5 s) | `1500` (15 s) | Interval between wakeups of the kernel dirty writeback daemon. |
| `vm.vfs_cache_pressure` | `100` | `50` | Reclaim priority for directory and inode caches. Lower values keep filesystem metadata cached in memory. |
| `vm.swappiness` | `60` | `10` (or `100` with zram) | Set to `10` when using disk swap to avoid disk thrashing; set to `100` when `zram-swap` is active to aggressively move cold memory into compressed RAM. |
| `fs.inotify.max_user_watches` | OS default | `1048576` | Prevents "system limit for number of file watchers reached" errors during large frontend or monorepo builds. Only raised, never lowered. |

> [!NOTE]
> **Why these values are moderate**: v1 configured aggressive ratios (`dirty_ratio=80`, `dirty_background_ratio=50`, `commit=600`). Under memory-intensive builds, this caused severe writeback bursts, kernel lockups, and unpredictable OOM-killer behavior. v2 uses moderate values that smooth I/O bursts and allow background writeback without freezing foreground compilers or starving memory.

### 3. Filesystem Remount (`remount-fast`)

Checks ext4 mountpoints for `/` and `/mnt` using `findmnt` and remounts them with high-throughput options:

```bash
mount -o remount,noatime,barrier=0,commit=60 "$mp"
```

- **`noatime`**: Eliminates access-time metadata write operations whenever files or directories are read.
- **`barrier=0`**: Disables ext4 write barriers on disk cache flushes. Since ephemeral runners are not expected to recover from power loss, barrier flushes impose unnecessary synchronization penalties.
- **`commit=60`**: Extends the ext4 journaling commit interval from 5 seconds to 60 seconds, reducing filesystem metadata journal writes 12x while avoiding v1's 600-second commit stall risks.
- Skipped on self-hosted runners unless `self-hosted-unsafe: true`.

### 4. Git Tuning via Environment Variables (`git-tuning`)

GitHub workflows spend measurable time reading index caches, computing diffs, and checking out refs. `overclock` applies Git optimizations purely through environment variables exported to `GITHUB_ENV` (`GIT_CONFIG_COUNT`, `GIT_CONFIG_KEY_<n>`, `GIT_CONFIG_VALUE_<n>`):

- `gc.auto=0` & `maintenance.auto=false`: Disables automated background garbage collection and repository maintenance.
- `checkout.workers=0`: Uses all available CPU cores for checkout file population.
- `fetch.parallel=0`: Fetches commit objects concurrently across all cores.
- `submodule.fetchJobs=0`: Clones and updates submodules in parallel.
- `core.untrackedCache=true`: Caches filesystem stat data for untracked files using directory modification times.

This configuration requires Git &ge; 2.31 (which introduced `GIT_CONFIG_KEY_<n>` support). If older, the action logs a status of `skipped`. It makes zero modifications to `/etc/gitconfig` or `~/.gitconfig`, leaving no persistent footprint.

### 5. Apt Tuning (`apt-tuning`)

Package installs during CI can stall on disk synchronization and post-install hooks (on GitHub-hosted runners the measured gain was within noise; it may matter more on slower self-hosted disks). When privileged, `overclock` applies system-level apt optimizations:

- **`force-unsafe-io`**: Writes `/etc/dpkg/dpkg.cfg.d/overclock-unsafe-io` with `force-unsafe-io`. This instructs `dpkg` to skip `fsync()` when unpacking and configuring packages.
- **Disable translation downloads**: Writes `/etc/apt/apt.conf.d/99overclock` containing `Acquire::Languages "none";`, preventing `apt update` from downloading localized package index translations.
- **Disable man-db indexing**: Removes `/var/lib/man-db/auto-update` to skip time-consuming manual database indexing when packages install man pages.
- **Stop background apt timers**: Runs `systemctl stop --no-block` on `apt-daily.timer`, `apt-daily-upgrade.timer`, `apt-daily.service`, `apt-daily-upgrade.service`, and `unattended-upgrades.service` to prevent background package managers from locking the dpkg database or contending for CPU.

### 6. Build Environment Tuning (`build-env`)

When opt-in `build-env: true` is configured, `overclock` inspects the runner's available CPU cores and exports build parallelism variables to `GITHUB_ENV` (only if not already set by the user):

- `MAKEFLAGS=-j<N>`
- `CMAKE_BUILD_PARALLEL_LEVEL=<N>`
- `CARGO_INCREMENTAL=0` (disables incremental compilation; in ephemeral CI with clean checkouts, incremental compilation adds hashing overhead and disk bloat without cache hit benefits)
- `CARGO_NET_GIT_FETCH_WITH_CLI=true` (uses the native `git` CLI for fast submodule and crate fetching)
- `MALLOC_ARENA_MAX=<N>` (restricts glibc malloc memory arenas to CPU count, reducing memory fragmentation in multithreaded builds)

### 7. Compressed zram Swap (`zram-swap`)

When `zram-swap: true` is configured:

1. The `zram` kernel module is loaded via `modprobe zram`.
2. A compressed swap block device is initialized via `zramctl --find --size <size> --algorithm <algo>`, testing algorithms in priority order: `zstd` &rarr; `lz4` &rarr; `lzo-rle` &rarr; kernel default.
3. The device is formatted with `mkswap` and activated with `swapon -p 100` (high priority).
4. `vm.swappiness` is set to `100`, directing the kernel to swap cold or idle memory into fast compressed RAM rather than triggering OOM kills or thrashing physical disk.

> [!NOTE]
> Unlike v1, which mounted a volatile ext4 volume directly over the workspace directory, v2 operates purely as an OS swap device. This eliminates workspace mount conflicts while providing extra memory headroom for high-RAM builds.

### 8. In-Memory tmpfs Mounts (`tmpfs-paths`)

Specific build caches or dependency directories can be mounted directly in RAM via `tmpfs-paths`:

- Configured as a comma-separated list of absolute paths (e.g. `tmpfs-paths: '~/.cache/pip,~/.cargo/registry'`). Leading `~/` expands to the runner's home directory.
- Existing directory contents are safely preserved into a temporary staging area and copied into the fresh tmpfs volume (`cp -a`), retaining file permissions and ownership.
- If target subdirectories do not exist, missing parent paths are created owned by the runner UID/GID so unprivileged subsequent steps retain write access.
- **Path validation**:
  - Relative paths are rejected.
  - Paths inside `$GITHUB_WORKSPACE` are rejected because `actions/checkout` removes the workspace using `io.rmRF()` prior to checkout; an active mountpoint inside the workspace causes `actions/checkout` to throw `EBUSY` and abort.
  - Critical system root directories (`/`, `/proc`, `/sys`, `/dev`, `/run`, `/boot`, `/etc`, `/usr`, `/var/lib/docker`, and `$HOME` itself) are strictly rejected.

---

## What It Does NOT Speed Up

`overclock` accelerates dynamic glibc file I/O and kernel buffering. It does not speed up:

1. **Go binaries**: The standard Go runtime (`CGO_ENABLED=0`) does not invoke glibc wrappers; it issues direct Linux kernel syscalls via assembly (`syscall.Syscall`). `LD_PRELOAD` interceptors cannot hook raw syscalls. (Go builds still benefit from page cache tuning, ext4 remounting, and Git tuning).
2. **Statically linked / musl binaries**: Statically linked binaries (e.g. binaries built with `-static` or compiled against musl libc on Alpine Linux) bypass the dynamic linker (`ld.so`), ignoring `LD_PRELOAD`.
3. **`io_uring`**: Applications performing asynchronous I/O via Linux `io_uring` bypass standard POSIX `fsync` and `open` libc calls.
4. **Docker daemon / containerd & service containers**: The Docker daemon and background service containers (e.g. `services: postgres`) execute in isolated host processes and namespaces. Environment variables exported to `GITHUB_ENV` do not propagate into background service containers.
   > [!TIP]
   > For PostgreSQL service containers, disable durability in the container command options:
   > ```yaml
   > services:
   >   postgres:
   >     image: postgres:16
   >     options: >-
   >       -c fsync=off
   >       -c synchronous_commit=off
   >       -c full_page_writes=off
   > ```
5. **macOS and Windows runners**: `overclock` is designed strictly for Linux. On macOS and Windows, it logs a notice and immediately exits `0` as a clean no-op.
6. **Container jobs (`container: ...`)**: Workflows executing within a job-level container run without root host capabilities, meaning kernel sysctls and filesystem remounts are skipped, and linker notices may occur if host paths differ.

---

## Known Caveats

- **`ld.so` notices in containers or 32-bit processes**: If a workflow step executes `docker run` and binds host environment variables, or executes a 32-bit binary on a 64-bit multiarch runner under `preload-scope: env`, the dynamic linker may print a notice: `ERROR: ld.so: object 'libnosync.so' from LD_PRELOAD cannot be preloaded: ignored`. This notice is harmless. If unwanted, disable fsync bypass (`fsync-bypass: false`).
- **`global` preload scope**: Setting `preload-scope: global` writes `/usr/lib/<triplet>/libnosync.so` into `/etc/ld.so.preload`. This hooks every dynamic process started on the host, including background system daemons and root commands. Use caution when enabling on persistent self-hosted runners.
- **Ephemeral durability trade-off**: Bypassing fsync and write barriers trades write durability for speed. This trade-off is safe for ephemeral CI runners destroyed after job completion, but must not be used on production database hosts.

---

## Migrating from v1

v2 removes several experimental or brittle tunings from v1 to improve stability and eliminate runner failures:

- **CPU governor**: GitHub Actions runners are virtual machines running under hypervisors where CPU frequency scaling sysctls are often virtualized or ineffective, producing spurious warnings.
- **I/O scheduler & block-queue tunings**: Modern cloud VMs use virtio-scsi or NVMe virtual storage devices where queue scheduling is managed by the host hypervisor; guest queue writes caused kernel errors.
- **BBR / TCP / qdisc / port range**: Network stack tweaks added fragility across kernel updates without measurable CI speedups.
- **`vm.overcommit_memory`, `kernel.*`, and `sched sysctls`**: Aggressive memory overcommit and scheduler tweaks led to sudden OOM killer crashes and instability under heavy load.
- **zram workspace & spill dirs**: Mounting a zram volume directly over `$GITHUB_WORKSPACE` broke `actions/checkout` cleanup (`EBUSY` error), required a brittle detached polling daemon, and risked sudden OOM. Replaced by `zram-swap` and opt-in `tmpfs-paths`.
- **Global build environment variables**: Setting `MAKEFLAGS` and `CMAKE_BUILD_PARALLEL_LEVEL` globally broke serial build jobs. Now opt-in via `build-env: true`.
- **`git config --system`**: Replaced by clean, non-persistent `GIT_CONFIG_*` environment variables with zero disk modification.

---

## Job Summary & Telemetry

At the conclusion of the job, `post.js` inspects `/proc/stat`, `/proc/vmstat`, `/proc/meminfo`, `/proc/diskstats`, and `NOSYNC_STATS_FILE`, rendering a report in `$GITHUB_STEP_SUMMARY`:

### Optimizations
| Optimization | Status | Detail |
|---|---|---|
| fsync bypass | ✅ active | scope: env (libnosync.so) [build: 72 ms] |
| page cache | ✅ active | dirty_ratio=45, dirty_background=15, swappiness=10, vfs=50 |
| remount | ✅ active | /:ok;/mnt:ok |
| git (env) | ✅ env | env-based (untrackedCache, checkout.workers, fetch.parallel, auto-gc off) |
| apt tuning | ✅ active | force-unsafe-io, acquire::languages=none, timers stopped |
| build env | ➖ disabled | disabled |
| zram swap | ➖ disabled | disabled |
| tmpfs paths | ➖ disabled | disabled |
| profile | ✅ hosted | hosted |

### fsync Bypass Impact
| Metric | Value |
|---|---|
| Sync calls skipped | 2,418 |
| O_SYNC / O_DSYNC stripped | 34 |
| Processes accelerated | 18 |

### System I/O Telemetry
| Metric | Value |
|---|---|
| Elapsed time | 48.20s |
| CPU iowait avg | 0.2% |
| CPU user+sys | 58.4% |
| Dirty now | 12.4 MiB |
| Writeback now | 0 B |
| Memory available / total | 6.8 GiB / 15.6 GiB |
| Page cache | 4.1 GiB |
| Swap used | 0 B |
| Data written to page cache (nr_dirtied) | 842.1 MiB |
| Physical disk writes | 114.2 MiB (1,240 IOs) |
| Physical disk reads | 42.0 MiB (480 IOs) |
| Disk busy % | 1.1% |
| Swap-out (pswpout) | 0 pages |
| OOM kills | ✅ 0 |

---

## Benchmarks

### Methodology

To eliminate cloud VM hardware variance and "noisy neighbor" effects across sequential runs, benchmarks are executed using an **in-VM interleaved A/B design** with an ablation study across four configurations:

1. **`baseline`**: Standard runner configuration (all overclock tunings disabled).
2. **`fsync`**: `libnosync.so` fsync bypass only.
3. **`kernel`**: Page cache sysctl tuning and ext4 remount only.
4. **`all`**: Full overclock acceleration (fsync bypass + kernel sysctl + ext4 remount + apt tuning).

Iterations follow a rotated Latin-square sequence across $N$ repetitions ($N=5$ by default). Before every timed iteration, page caches are cleared untimed (`sync; echo 3 > /proc/sys/vm/drop_caches`). Results report the median execution time, Interquartile Range (IQR), median speedup ratio vs. baseline, and a 95% bootstrap confidence interval (2,000 resamples). Speedups whose confidence interval includes 1.0 are marked as not statistically significant.

Workloads evaluated:
- **`sqlite`**: 2,000 synchronous transactions (`PRAGMA synchronous=FULL`).
- **`smallfiles`**: Unpack 30,000 files from tarball, staged git commit, and recursive removal.
- **`npm-ci`**: Realistic multi-dependency Node.js project unpack from a warmed offline cache.
- **`pip-install`**: Python package installation from a warmed wheel cache into a clean virtualenv.
- **`apt-reinstall`**: Reinstallation of cached deb packages via dpkg and apt.
- **`cargo-build`**: Clean compilation of a Rust crate with pre-fetched dependencies.

<!-- BENCH-RESULTS:START -->
Measured 2026-11-06 on GitHub-hosted runners. Speedup = baseline median / config median, 5 interleaved reps per config in the same VM. "sig." means the 95% bootstrap CI of the ratio excludes 1.0.

| Workload | `ubuntu-24.04` (x86_64), `all` | `ubuntu-24.04-arm`, `all` | fsyncs skipped |
|---|---|---|---|
| SQLite, 2,000 `synchronous=FULL` commits | **6.96×** (1,349 → 194 ms, sig.) | **15.8×** (1,339 → 85 ms, sig.) | 40,020 |
| 30k small files: extract + git add/commit + rm | 1.02× (sig.) | 1.03× (sig.) | 0 |
| `apt-get install --reinstall` (offline) | 0.98× (n.s.) | 0.97× (n.s.) | ~78,600 |
| `npm ci` (offline cache) | 1.01× (n.s.) | 1.01× (n.s.) | 0 |
| `pip install` (offline wheels) | 1.01× (n.s.) | 1.01× (n.s.) | 180 |
| `cargo build` (deps prefetched) | 1.01× (n.s.) | 1.01× (n.s.) | 0 |

Real projects (`ubuntu-24.04`, `baseline` vs `all`, 3 reps, three separate workflow runs):

| Project | Run 1 | Run 2 | Run 3 |
|---|---|---|---|
| vue-core (install + build + unit tests) | 1.02× | 0.99× | 1.02× |
| ripgrep (release build + tests) | 1.00× | 1.00× | 1.00× |
| redis (build) | 1.04× | 1.00× | 1.00× |

**Takeaways.** fsync on hosted runners costs roughly 30 µs, so skipping it only matters when a workload issues tens of thousands of *serialised* syncs (database commits). Package managers and compilers barely sync, so expect gains within noise for typical npm/pip/cargo/make jobs. Absolute times varied by up to 40% between runs because runners land on different hardware, which is why the comparison is done in-VM.
<!-- BENCH-RESULTS:END -->

### Reproducing Benchmarks

Run the benchmark workflow on your fork or repository:

```bash
gh workflow run benchmark.yml -f reps=5
```

Real-world application benchmarks (`vue-core`, `ripgrep`, `fastapi`, `redis`) can be executed via:

```bash
gh workflow run real-world-benchmark.yml -f reps=3
```

---

## Development

The codebase has zero npm runtime dependencies and uses standard Node.js built-ins (`node:test`, `child_process`, `fs`, `os`, `path`).

- **Run unit tests**:
  ```bash
  npm test
  ```
- **Lint JavaScript**:
  ```bash
  npm run lint
  ```
- **Lint bash scripts**:
  ```bash
  shellcheck src/*.sh bench/*.sh bench/workloads/*.sh test/*.sh
  ```
- **Run nosync integration tests** (Linux with gcc, python3, and strace):
  ```bash
  bash test/nosync_test.sh
  ```

---

## Releasing

To release a new version, create a semantic version tag and update the moving major tag:

```bash
git tag -fa v2.0.0 -m "Release v2.0.0"
git tag -fa v2 -m "Release v2"
git push origin v2.0.0
git push origin v2 --force
```

For reproducible and secure CI pipelines, we recommend pinning to a specific commit SHA:

```yaml
- uses: boazberman/overclock@<commit-sha> # v2
```

---

## License

Released under the [Business Source License 1.1](LICENSE) (BUSL-1.1). Free for internal commercial and non-commercial CI/CD use; cannot be sold, sublicensed, or incorporated into commercial products or services distributed to third parties. Automatically converts to the MIT License on 2030-01-01.
