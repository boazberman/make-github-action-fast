#!/usr/bin/env bash
set -euo pipefail

# bench/knobs.sh - Configure system knobs for overclock benchmarking
# Usage: bench/knobs.sh <baseline|fsync|kernel|all>

CONFIG="${1:-}"
if [ -z "$CONFIG" ]; then
  echo "Usage: $0 <baseline|fsync|kernel|all>" >&2
  exit 1
fi

DEFAULTS_FILE="${RUNNER_TEMP:-/tmp}/bench-defaults.env"

# Capture image defaults once on first invocation
if [ ! -f "$DEFAULTS_FILE" ]; then
  mkdir -p "$(dirname "$DEFAULTS_FILE")"
  orig_dirty_ratio=$(sysctl -n vm.dirty_ratio 2>/dev/null || cat /proc/sys/vm/dirty_ratio 2>/dev/null || echo 20)
  orig_dirty_bg_ratio=$(sysctl -n vm.dirty_background_ratio 2>/dev/null || cat /proc/sys/vm/dirty_background_ratio 2>/dev/null || echo 10)
  orig_dirty_expire=$(sysctl -n vm.dirty_expire_centisecs 2>/dev/null || cat /proc/sys/vm/dirty_expire_centisecs 2>/dev/null || echo 3000)
  orig_dirty_writeback=$(sysctl -n vm.dirty_writeback_centisecs 2>/dev/null || cat /proc/sys/vm/dirty_writeback_centisecs 2>/dev/null || echo 500)
  orig_vfs_cache=$(sysctl -n vm.vfs_cache_pressure 2>/dev/null || cat /proc/sys/vm/vfs_cache_pressure 2>/dev/null || echo 100)
  orig_swappiness=$(sysctl -n vm.swappiness 2>/dev/null || cat /proc/sys/vm/swappiness 2>/dev/null || echo 60)
  orig_watches=$(sysctl -n fs.inotify.max_user_watches 2>/dev/null || cat /proc/sys/fs/inotify/max_user_watches 2>/dev/null || echo 8192)
  orig_mandb=0
  if [ -f /var/lib/man-db/auto-update ]; then
    orig_mandb=1
  fi

  cat <<EOF > "$DEFAULTS_FILE"
ORIG_DIRTY_RATIO="$orig_dirty_ratio"
ORIG_DIRTY_BG_RATIO="$orig_dirty_bg_ratio"
ORIG_DIRTY_EXPIRE="$orig_dirty_expire"
ORIG_DIRTY_WRITEBACK="$orig_dirty_writeback"
ORIG_VFS_CACHE="$orig_vfs_cache"
ORIG_SWAPPINESS="$orig_swappiness"
ORIG_WATCHES="$orig_watches"
ORIG_MANDB="$orig_mandb"
EOF
fi

# Declare variables populated by source
ORIG_DIRTY_RATIO="${ORIG_DIRTY_RATIO:-20}"
ORIG_DIRTY_BG_RATIO="${ORIG_DIRTY_BG_RATIO:-10}"
ORIG_DIRTY_EXPIRE="${ORIG_DIRTY_EXPIRE:-3000}"
ORIG_DIRTY_WRITEBACK="${ORIG_DIRTY_WRITEBACK:-500}"
ORIG_VFS_CACHE="${ORIG_VFS_CACHE:-100}"
ORIG_SWAPPINESS="${ORIG_SWAPPINESS:-60}"
ORIG_WATCHES="${ORIG_WATCHES:-8192}"
ORIG_MANDB="${ORIG_MANDB:-0}"

# Source captured defaults
# shellcheck source=/dev/null
source "$DEFAULTS_FILE"

remount_ext4() {
  local opts="$1"
  for target in / /mnt; do
    if [ -d "$target" ]; then
      local fstype
      fstype=$(findmnt -n -o FSTYPE "$target" 2>/dev/null || true)
      if [ "$fstype" = "ext4" ]; then
        mount -o "remount,$opts" "$target" 2>/dev/null || true
      fi
    fi
  done
}

case "$CONFIG" in
  baseline|fsync)
    # Restore defaults
    # Set dirty_background_ratio before dirty_ratio to ensure bg <= ratio
    sysctl -w vm.dirty_background_ratio="$ORIG_DIRTY_BG_RATIO" 2>/dev/null || true
    sysctl -w vm.dirty_ratio="$ORIG_DIRTY_RATIO" 2>/dev/null || true
    sysctl -w vm.dirty_expire_centisecs="$ORIG_DIRTY_EXPIRE" 2>/dev/null || true
    sysctl -w vm.dirty_writeback_centisecs="$ORIG_DIRTY_WRITEBACK" 2>/dev/null || true
    sysctl -w vm.vfs_cache_pressure="$ORIG_VFS_CACHE" 2>/dev/null || true
    sysctl -w vm.swappiness="$ORIG_SWAPPINESS" 2>/dev/null || true
    sysctl -w fs.inotify.max_user_watches="$ORIG_WATCHES" 2>/dev/null || true

    remount_ext4 "relatime,barrier=1,commit=5"

    rm -f /etc/dpkg/dpkg.cfg.d/overclock-unsafe-io
    rm -f /etc/apt/apt.conf.d/99overclock
    if [ "${ORIG_MANDB:-0}" = "1" ]; then
      touch /var/lib/man-db/auto-update 2>/dev/null || true
    fi
    ;;

  kernel)
    # Set dirty_ratio first per spec §1 (45 >= current bg), then bg (15 <= 45)
    sysctl -w vm.dirty_ratio=45 2>/dev/null || true
    sysctl -w vm.dirty_background_ratio=15 2>/dev/null || true
    sysctl -w vm.dirty_expire_centisecs=3000 2>/dev/null || true
    sysctl -w vm.dirty_writeback_centisecs=1500 2>/dev/null || true
    sysctl -w vm.vfs_cache_pressure=50 2>/dev/null || true
    sysctl -w vm.swappiness=10 2>/dev/null || true

    cur_watches=$(sysctl -n fs.inotify.max_user_watches 2>/dev/null || cat /proc/sys/fs/inotify/max_user_watches 2>/dev/null || echo 0)
    if [ "$cur_watches" -lt 1048576 ]; then
      sysctl -w fs.inotify.max_user_watches=1048576 2>/dev/null || true
    fi

    remount_ext4 "noatime,barrier=0,commit=60"

    # apt is baseline for kernel-only config
    rm -f /etc/dpkg/dpkg.cfg.d/overclock-unsafe-io
    rm -f /etc/apt/apt.conf.d/99overclock
    if [ "${ORIG_MANDB:-0}" = "1" ]; then
      touch /var/lib/man-db/auto-update 2>/dev/null || true
    fi
    ;;

  all)
    sysctl -w vm.dirty_ratio=45 2>/dev/null || true
    sysctl -w vm.dirty_background_ratio=15 2>/dev/null || true
    sysctl -w vm.dirty_expire_centisecs=3000 2>/dev/null || true
    sysctl -w vm.dirty_writeback_centisecs=1500 2>/dev/null || true
    sysctl -w vm.vfs_cache_pressure=50 2>/dev/null || true
    sysctl -w vm.swappiness=10 2>/dev/null || true

    cur_watches=$(sysctl -n fs.inotify.max_user_watches 2>/dev/null || cat /proc/sys/fs/inotify/max_user_watches 2>/dev/null || echo 0)
    if [ "$cur_watches" -lt 1048576 ]; then
      sysctl -w fs.inotify.max_user_watches=1048576 2>/dev/null || true
    fi

    remount_ext4 "noatime,barrier=0,commit=60"

    mkdir -p /etc/dpkg/dpkg.cfg.d /etc/apt/apt.conf.d 2>/dev/null || true
    echo "force-unsafe-io" > /etc/dpkg/dpkg.cfg.d/overclock-unsafe-io 2>/dev/null || true
    echo 'Acquire::Languages "none";' > /etc/apt/apt.conf.d/99overclock 2>/dev/null || true
    rm -f /var/lib/man-db/auto-update

    if command -v systemctl >/dev/null 2>&1; then
      systemctl stop --no-block apt-daily.timer apt-daily-upgrade.timer apt-daily.service apt-daily-upgrade.service unattended-upgrades.service 2>/dev/null || true
    fi
    ;;

  *)
    echo "Unknown configuration: $CONFIG" >&2
    exit 1
    ;;
esac
