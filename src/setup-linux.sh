#!/usr/bin/env bash
# overclock - Linux root optimization engine v2
# Modes: setup (default), teardown

set -uo pipefail

OVERCLOCK_ACTION_PATH="${OVERCLOCK_ACTION_PATH:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
OVERCLOCK_PROFILE="${OVERCLOCK_PROFILE:-hosted}"
OVERCLOCK_STATE_DIR="${OVERCLOCK_STATE_DIR:-/tmp/overclock}"
OVERCLOCK_FSYNC_BYPASS="${OVERCLOCK_FSYNC_BYPASS:-true}"
OVERCLOCK_PRELOAD_SCOPE="${OVERCLOCK_PRELOAD_SCOPE:-env}"
OVERCLOCK_PAGE_CACHE="${OVERCLOCK_PAGE_CACHE:-true}"
OVERCLOCK_REMOUNT="${OVERCLOCK_REMOUNT:-true}"
OVERCLOCK_APT_TUNING="${OVERCLOCK_APT_TUNING:-true}"
OVERCLOCK_ZRAM_SWAP="${OVERCLOCK_ZRAM_SWAP:-false}"
OVERCLOCK_ZRAM_SWAP_SIZE="${OVERCLOCK_ZRAM_SWAP_SIZE:-50%}"
OVERCLOCK_TMPFS_PATHS="${OVERCLOCK_TMPFS_PATHS:-}"
OVERCLOCK_TMPFS_SIZE="${OVERCLOCK_TMPFS_SIZE:-50%}"
OVERCLOCK_SELF_HOSTED_UNSAFE="${OVERCLOCK_SELF_HOSTED_UNSAFE:-false}"
OVERCLOCK_WORKSPACE="${OVERCLOCK_WORKSPACE:-$(pwd)}"
OVERCLOCK_UID="${OVERCLOCK_UID:-$(id -u)}"
OVERCLOCK_GID="${OVERCLOCK_GID:-$(id -g)}"
OVERCLOCK_START_EPOCH_MS="${OVERCLOCK_START_EPOCH_MS:-}"

STATE_FILE="$OVERCLOCK_STATE_DIR/state.env"
METRICS_FILE="$OVERCLOCK_STATE_DIR/metrics-start.env"
SETUP_LOG="$OVERCLOCK_STATE_DIR/setup.log"
STATS_FILE="$OVERCLOCK_STATE_DIR/nosync-stats"

IS_ROOT="false"
if [[ "$(id -u)" -eq 0 ]]; then
  IS_ROOT="true"
fi

log() {
  printf '[overclock] %s\n' "$1" | tee -a "$SETUP_LOG"
}

warn() {
  printf '::warning title=overclock::%s\n' "$1"
  printf '[overclock WARNING] %s\n' "$1" >> "$SETUP_LOG"
}

record_status() {
  local feat="$1"
  local status="$2"
  local detail="${3:-}"
  printf '%s=%s\n' "$feat" "$status" >> "$STATE_FILE"
  if [[ -n "$detail" ]]; then
    printf '%s_DETAIL=%s\n' "$feat" "$detail" >> "$STATE_FILE"
  fi
}

write_compile_result() {
  local file="$1"
  local status="$2"
  local lib_path="$3"
  local preload_val="$4"
  local compile_ms="$5"
  local scope="$6"
  local installed_lib="${7:-}"
  local orig_preload="${8:-}"
  local err="${9:-}"

  cat <<EOF > "$file"
STATUS=$status
LIB_PATH=$lib_path
LD_PRELOAD_VALUE=$preload_val
COMPILE_MS=$compile_ms
PRELOAD_SCOPE=$scope
INSTALLED_SYSTEM_LIB=$installed_lib
ORIG_LD_SO_PRELOAD=$orig_preload
ERR=$err
EOF
}

mode_teardown() {
  log "Teardown initiated"

  local orig_sysctl=""
  local remounted_mounts=""
  local man_db_existed=""
  local orig_preload=""
  local tmpfs_mounted=""
  local zram_dev=""
  local installed_lib=""

  if [[ -f "$STATE_FILE" ]]; then
    while IFS='=' read -r k v || [[ -n "$k" ]]; do
      case "$k" in
        ORIG_SYSCTL) orig_sysctl="$v" ;;
        REMOUNTED_MOUNTS) remounted_mounts="$v" ;;
        MAN_DB_AUTO_UPDATE_EXISTED) man_db_existed="$v" ;;
        ORIG_LD_SO_PRELOAD) orig_preload="$v" ;;
        TMPFS_MOUNTED) tmpfs_mounted="$v" ;;
        ZRAM_DEV) zram_dev="$v" ;;
        INSTALLED_SYSTEM_LIB) installed_lib="$v" ;;
      esac
    done < "$STATE_FILE"
  fi

  # 1. Restore sysctls
  if [[ -n "$orig_sysctl" ]]; then
    local pairs=()
    IFS=',' read -r -a pairs <<< "$orig_sysctl"
    for pair in "${pairs[@]}"; do
      local k="${pair%%:*}"
      local v="${pair#*:}"
      local p="/proc/sys/${k//.//}"
      if [[ -w "$p" ]]; then
        printf '%s' "$v" > "$p" 2>>"$SETUP_LOG" || true
      fi
    done
  fi

  # 2. Restore remounts
  if [[ -n "$remounted_mounts" ]]; then
    local m_array=()
    IFS=' ' read -r -a m_array <<< "$remounted_mounts"
    for mp in "${m_array[@]}"; do
      [[ -n "$mp" ]] || continue
      mount -o remount,barrier=1,commit=5,relatime "$mp" 2>>"$SETUP_LOG" || true
    done
  fi

  # 3. Restore apt configuration
  rm -f /etc/dpkg/dpkg.cfg.d/overclock-unsafe-io /etc/apt/apt.conf.d/99overclock 2>>"$SETUP_LOG" || true
  if [[ "$man_db_existed" == "true" ]]; then
    touch /var/lib/man-db/auto-update 2>>"$SETUP_LOG" || true
  fi
  systemctl start --no-block apt-daily.timer apt-daily-upgrade.timer apt-daily.service apt-daily-upgrade.service unattended-upgrades.service 2>>"$SETUP_LOG" || true

  # 4. Restore /etc/ld.so.preload
  if [[ "$orig_preload" == "present" && -f "$OVERCLOCK_STATE_DIR/orig_ld_so_preload" ]]; then
    cp "$OVERCLOCK_STATE_DIR/orig_ld_so_preload" /etc/ld.so.preload 2>>"$SETUP_LOG" || true
  elif [[ "$orig_preload" == "absent" ]]; then
    rm -f /etc/ld.so.preload 2>>"$SETUP_LOG" || true
  fi

  # 5. Unmount tmpfs
  if [[ -n "$tmpfs_mounted" ]]; then
    local t_array=()
    IFS=',' read -r -a t_array <<< "$tmpfs_mounted"
    for p in "${t_array[@]}"; do
      [[ -n "$p" ]] || continue
      umount -l "$p" 2>>"$SETUP_LOG" || true
    done
  fi

  # 6. Reset zram swap
  if [[ -n "$zram_dev" && -b "$zram_dev" ]]; then
    swapoff "$zram_dev" 2>>"$SETUP_LOG" || true
    zramctl --reset "$zram_dev" 2>>"$SETUP_LOG" || true
  fi

  # 7. Remove installed system lib
  if [[ -n "$installed_lib" && -f "$installed_lib" ]]; then
    rm -f "$installed_lib" 2>>"$SETUP_LOG" || true
  fi

  log "Teardown complete"
  exit 0
}

mode_setup() {
  local script_start_ms
  script_start_ms="$(date +%s%3N 2>/dev/null || printf '%s000' "$(date +%s)")"

  mkdir -p "$OVERCLOCK_STATE_DIR" "$OVERCLOCK_STATE_DIR/lib" 2>/dev/null || true
  : > "$SETUP_LOG"
  : > "$STATE_FILE"
  chmod 0644 "$STATE_FILE" 2>>"$SETUP_LOG" || true

  # Create empty stats file with mode 0666
  if [[ ! -f "$STATS_FILE" ]]; then
    : > "$STATS_FILE"
  fi
  chmod 0666 "$STATS_FILE" 2>>"$SETUP_LOG" || true

  # 1. Baseline telemetry -> metrics file
  : > "$METRICS_FILE"
  chmod 0644 "$METRICS_FILE" 2>>"$SETUP_LOG" || true

  local start_epoch="$OVERCLOCK_START_EPOCH_MS"
  if [[ -z "$start_epoch" ]]; then
    start_epoch="$(date +%s%3N 2>/dev/null || printf '%s000' "$(date +%s)")"
  fi

  local start_uptime="0"
  if [[ -r /proc/uptime ]]; then
    read -r start_uptime _ < /proc/uptime || true
  fi

  local cpu_stat=""
  if [[ -r /proc/stat ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
      if [[ "$line" =~ ^cpu[[:space:]]+(.*)$ ]]; then
        cpu_stat="${BASH_REMATCH[1]}"
        break
      fi
    done < /proc/stat
  fi

  {
    printf 'START_EPOCH_MS=%s\n' "$start_epoch"
    printf 'START_UPTIME=%s\n' "$start_uptime"
    printf 'CPU_STAT=%s\n' "$cpu_stat"
  } >> "$METRICS_FILE"

  if [[ -r /proc/vmstat ]]; then
    awk '$1 ~ /^(pgpgin|pgpgout|pswpin|pswpout|nr_dirtied|nr_written|pgmajfault|oom_kill)$/ { print "VMSTAT_" $1 "=" $2 }' /proc/vmstat >> "$METRICS_FILE" 2>>"$SETUP_LOG" || true
  fi

  local devs=()
  if [[ -d /sys/block ]]; then
    shopt -s nullglob
    for b in /sys/block/*; do
      [[ -e "$b" ]] || continue
      local d="${b##*/}"
      case "$d" in
        loop*|ram*|zram*|sr*|fd*|nbd*) ;;
        *) devs+=("$d") ;;
      esac
    done
    shopt -u nullglob
  fi

  local disk_devs=""
  if [[ ${#devs[@]} -gt 0 ]]; then
    disk_devs=$(IFS=,; echo "${devs[*]}")
  fi
  printf 'DISK_DEVICES=%s\n' "$disk_devs" >> "$METRICS_FILE"

  if [[ -n "$disk_devs" && -r /proc/diskstats ]]; then
    awk -v devs="$disk_devs" '
    BEGIN {
      split(devs, d, ",");
      for (i in d) valid[d[i]] = 1;
      r_ios = 0; r_sec = 0; w_ios = 0; w_sec = 0; ticks = 0;
    }
    $3 in valid {
      r_ios += $4;
      r_sec += $6;
      w_ios += $8;
      w_sec += $10;
      ticks += $13;
    }
    END {
      print "DISK_READ_IOS=" r_ios;
      print "DISK_READ_SECTORS=" r_sec;
      print "DISK_WRITE_IOS=" w_ios;
      print "DISK_WRITE_SECTORS=" w_sec;
      print "DISK_IO_TICKS_MS=" ticks;
    }' /proc/diskstats >> "$METRICS_FILE" 2>>"$SETUP_LOG" || true
  else
    printf 'DISK_READ_IOS=0\nDISK_READ_SECTORS=0\nDISK_WRITE_IOS=0\nDISK_WRITE_SECTORS=0\nDISK_IO_TICKS_MS=0\n' >> "$METRICS_FILE"
  fi

  # 2. Background libnosync compile & preload setup
  local compile_pid=""
  local build_tmp=""
  local compile_result=""

  if [[ "$OVERCLOCK_FSYNC_BYPASS" == "true" ]]; then
    build_tmp="$(mktemp -d /tmp/overclock-build.XXXXXX 2>>"$SETUP_LOG" || true)"
    if [[ -n "$build_tmp" && -d "$build_tmp" ]]; then
      compile_result="$build_tmp/result.env"
      local nosync_src="$OVERCLOCK_ACTION_PATH/src/nosync.c"

      (
        local t_cstart
        t_cstart="$(date +%s%3N 2>/dev/null || printf '%s000' "$(date +%s)")"

        if [[ ! -r "$nosync_src" ]]; then
          local t_cend
          t_cend="$(date +%s%3N 2>/dev/null || printf '%s000' "$(date +%s)")"
          write_compile_result "$compile_result" "failed" "" "" "$(( t_cend - t_cstart ))" "env" "" "" "nosync.c not found"
          exit 0
        fi

        if ! command -v gcc >/dev/null 2>&1; then
          local t_cend
          t_cend="$(date +%s%3N 2>/dev/null || printf '%s000' "$(date +%s)")"
          write_compile_result "$compile_result" "failed" "" "" "$(( t_cend - t_cstart ))" "env" "" "" "gcc not found"
          exit 0
        fi

        local tmp_so="$build_tmp/libnosync.so"
        if ! gcc -O2 -shared -fPIC -pthread -U_FORTIFY_SOURCE -D_GNU_SOURCE -Wall -Wextra -Werror -o "$tmp_so" "$nosync_src" -ldl >>"$SETUP_LOG" 2>&1; then
          local t_cend
          t_cend="$(date +%s%3N 2>/dev/null || printf '%s000' "$(date +%s)")"
          write_compile_result "$compile_result" "failed" "" "" "$(( t_cend - t_cstart ))" "env" "" "" "gcc compilation failed"
          exit 0
        fi

        local lib_path=""
        local preload_val=""
        local installed_system_lib=""

        if [[ "$IS_ROOT" == "true" && ( "$OVERCLOCK_PROFILE" == "hosted" || "$OVERCLOCK_PROFILE" == "self-hosted-unsafe" ) ]]; then
          local triplet=""
          triplet="$(gcc -dumpmachine 2>>"$SETUP_LOG" || true)"
          if [[ -n "$triplet" && -d "/usr/lib/$triplet" ]]; then
            if install -m 4755 "$tmp_so" "/usr/lib/$triplet/libnosync.so" 2>>"$SETUP_LOG"; then
              lib_path="/usr/lib/$triplet/libnosync.so"
              preload_val="libnosync.so"
              installed_system_lib="/usr/lib/$triplet/libnosync.so"
            fi
          fi
          if [[ -z "$lib_path" ]]; then
            if install -m 0755 "$tmp_so" "$OVERCLOCK_STATE_DIR/lib/libnosync.so" 2>>"$SETUP_LOG"; then
              lib_path="$OVERCLOCK_STATE_DIR/lib/libnosync.so"
              preload_val="$OVERCLOCK_STATE_DIR/lib/libnosync.so"
            fi
          fi
        else
          if install -m 0755 "$tmp_so" "$OVERCLOCK_STATE_DIR/lib/libnosync.so" 2>>"$SETUP_LOG"; then
            lib_path="$OVERCLOCK_STATE_DIR/lib/libnosync.so"
            preload_val="$OVERCLOCK_STATE_DIR/lib/libnosync.so"
          fi
        fi

        if [[ -z "$lib_path" ]]; then
          local t_cend
          t_cend="$(date +%s%3N 2>/dev/null || printf '%s000' "$(date +%s)")"
          write_compile_result "$compile_result" "failed" "" "" "$(( t_cend - t_cstart ))" "env" "" "" "installation of libnosync.so failed"
          exit 0
        fi

        local scope_result="env"
        local orig_preload_state=""
        if [[ "$OVERCLOCK_PRELOAD_SCOPE" == "global" && "$IS_ROOT" == "true" && ( "$OVERCLOCK_PROFILE" == "hosted" || "$OVERCLOCK_PROFILE" == "self-hosted-unsafe" ) ]]; then
          if [[ -f /etc/ld.so.preload ]]; then
            cp /etc/ld.so.preload "$OVERCLOCK_STATE_DIR/orig_ld_so_preload" 2>>"$SETUP_LOG" || true
            orig_preload_state="present"
          else
            orig_preload_state="absent"
          fi
          printf '%s\n' "$lib_path" >> /etc/ld.so.preload 2>>"$SETUP_LOG" || true
          scope_result="global"
        fi

        local t_cend
        t_cend="$(date +%s%3N 2>/dev/null || printf '%s000' "$(date +%s)")"
        write_compile_result "$compile_result" "active" "$lib_path" "$preload_val" "$(( t_cend - t_cstart ))" "$scope_result" "$installed_system_lib" "$orig_preload_state" ""
      ) >>"$SETUP_LOG" 2>&1 &
      compile_pid=$!
    else
      warn "failed to create temp dir for libnosync build"
    fi
  fi

  # 3. Page cache tuning
  if [[ "$OVERCLOCK_PAGE_CACHE" != "true" ]]; then
    record_status PAGE_CACHE "disabled"
  elif [[ "$IS_ROOT" != "true" ]]; then
    record_status PAGE_CACHE "skipped" "non-root"
  else
    local sysctl_keys=(
      "vm.dirty_ratio"
      "vm.dirty_background_ratio"
      "vm.dirty_expire_centisecs"
      "vm.dirty_writeback_centisecs"
      "vm.vfs_cache_pressure"
      "vm.swappiness"
      "fs.inotify.max_user_watches"
    )
    local swappiness_val="10"
    if [[ "$OVERCLOCK_ZRAM_SWAP" == "true" ]]; then
      swappiness_val="100"
    fi

    local sysctl_vals=(
      "45"
      "15"
      "3000"
      "1500"
      "50"
      "$swappiness_val"
      "1048576"
    )

    local orig_pairs=()
    for k in "${sysctl_keys[@]}"; do
      local p="/proc/sys/${k//.//}"
      if [[ -r "$p" ]]; then
        local cur_val=""
        read -r cur_val < "$p" 2>>"$SETUP_LOG" || cur_val=""
        orig_pairs+=("$k:$cur_val")
      fi
    done
    if [[ ${#orig_pairs[@]} -gt 0 ]]; then
      local orig_str
      orig_str=$(IFS=,; echo "${orig_pairs[*]}")
      printf 'ORIG_SYSCTL=%s\n' "$orig_str" >> "$STATE_FILE"
    fi

    local success_cnt=0
    local fail_cnt=0
    for idx in "${!sysctl_keys[@]}"; do
      local k="${sysctl_keys[$idx]}"
      local v="${sysctl_vals[$idx]}"
      local p="/proc/sys/${k//.//}"
      if [[ ! -e "$p" ]]; then
        continue
      fi

      if [[ "$k" == "fs.inotify.max_user_watches" ]]; then
        local cur_watches=0
        read -r cur_watches < "$p" 2>>"$SETUP_LOG" || cur_watches=0
        if [[ "$cur_watches" -ge 1048576 ]]; then
          ((success_cnt++)) || true
          continue
        fi
      fi

      if printf '%s' "$v" > "$p" 2>>"$SETUP_LOG"; then
        ((success_cnt++)) || true
      else
        ((fail_cnt++)) || true
      fi
    done

    if [[ "$fail_cnt" -eq 0 ]]; then
      record_status PAGE_CACHE "active"
    elif [[ "$success_cnt" -gt 0 ]]; then
      record_status PAGE_CACHE "partial"
    else
      record_status PAGE_CACHE "failed"
    fi
  fi

  # 4. Filesystem remount
  if [[ "$OVERCLOCK_REMOUNT" != "true" ]]; then
    record_status REMOUNT "disabled"
  elif [[ "$IS_ROOT" != "true" ]]; then
    record_status REMOUNT "skipped" "non-root"
  elif [[ "$OVERCLOCK_PROFILE" == "self-hosted-safe" ]]; then
    record_status REMOUNT "skipped" "self-hosted-safe"
  else
    local remounted=()
    local remount_details=()
    local any_ext4=0

    for mp in / /mnt; do
      local fstype
      fstype="$(findmnt -rn -o FSTYPE --mountpoint "$mp" 2>>"$SETUP_LOG" || true)"
      if [[ -z "$fstype" ]]; then
        remount_details+=("$mp:absent")
      elif [[ "$fstype" != "ext4" ]]; then
        remount_details+=("$mp:not-ext4:$fstype")
      else
        any_ext4=1
        if mount -o remount,noatime,barrier=0,commit=60 "$mp" 2>>"$SETUP_LOG"; then
          remount_details+=("$mp:ok")
          remounted+=("$mp")
        else
          remount_details+=("$mp:failed")
        fi
      fi
    done

    local detail_str
    detail_str=$(IFS=';'; echo "${remount_details[*]}")
    if [[ ${#remounted[@]} -gt 0 ]]; then
      record_status REMOUNT "active" "$detail_str"
      printf 'REMOUNTED_MOUNTS=%s\n' "${remounted[*]}" >> "$STATE_FILE"
    elif [[ "$any_ext4" -eq 1 ]]; then
      record_status REMOUNT "failed" "$detail_str"
    else
      record_status REMOUNT "skipped" "$detail_str"
    fi
  fi

  # 5. Apt tuning
  if [[ "$OVERCLOCK_APT_TUNING" != "true" ]]; then
    record_status APT_TUNING "disabled"
  elif [[ "$IS_ROOT" != "true" ]]; then
    record_status APT_TUNING "skipped" "non-root"
  else
    mkdir -p /etc/dpkg/dpkg.cfg.d /etc/apt/apt.conf.d 2>>"$SETUP_LOG" || true
    printf 'force-unsafe-io\n' > /etc/dpkg/dpkg.cfg.d/overclock-unsafe-io 2>>"$SETUP_LOG" || true
    printf 'Acquire::Languages "none";\n' > /etc/apt/apt.conf.d/99overclock 2>>"$SETUP_LOG" || true

    if [[ -e /var/lib/man-db/auto-update ]]; then
      printf 'MAN_DB_AUTO_UPDATE_EXISTED=true\n' >> "$STATE_FILE"
      rm -f /var/lib/man-db/auto-update 2>>"$SETUP_LOG" || true
    else
      printf 'MAN_DB_AUTO_UPDATE_EXISTED=false\n' >> "$STATE_FILE"
    fi

    systemctl stop --no-block apt-daily.timer apt-daily-upgrade.timer apt-daily.service apt-daily-upgrade.service unattended-upgrades.service 2>>"$SETUP_LOG" || true
    record_status APT_TUNING "active"
  fi

  # 6. zram swap
  if [[ "$OVERCLOCK_ZRAM_SWAP" != "true" ]]; then
    record_status ZRAM_SWAP "disabled"
  elif [[ "$IS_ROOT" != "true" ]]; then
    record_status ZRAM_SWAP "skipped" "non-root"
  else
    modprobe zram 2>>"$SETUP_LOG" || true
    if [[ ! -e /sys/class/zram-control && ! -e /dev/zram0 ]]; then
      warn "zram kernel module not available or unsupported in this kernel"
      record_status ZRAM_SWAP "unsupported" "module unavailable"
    else
      # Calculate swap size in bytes
      local size_bytes=0
      if [[ "$OVERCLOCK_ZRAM_SWAP_SIZE" =~ ^([0-9]+)%$ ]]; then
        local pct="${BASH_REMATCH[1]}"
        local mem_total_kb=0
        if [[ -r /proc/meminfo ]]; then
          while IFS=':' read -r mk mv || [[ -n "$mk" ]]; do
            if [[ "$mk" == "MemTotal" ]]; then
              mem_total_kb="$(awk '{print $1}' <<< "$mv")"
              break
            fi
          done < /proc/meminfo
        fi
        if [[ "$mem_total_kb" -gt 0 ]]; then
          local mem_total_bytes=$(( mem_total_kb * 1024 ))
          size_bytes=$(( mem_total_bytes * pct / 100 ))
        fi
      fi

      if [[ "$size_bytes" -le 0 ]]; then
        # Parse absolute sizes like 4G, 512M
        size_bytes="$(awk -v s="$OVERCLOCK_ZRAM_SWAP_SIZE" 'BEGIN {
          u = toupper(substr(s, length(s)));
          n = s;
          mult = 1;
          if (u == "K") { mult = 1024; n = substr(s, 1, length(s)-1); }
          else if (u == "M") { mult = 1024*1024; n = substr(s, 1, length(s)-1); }
          else if (u == "G") { mult = 1024*1024*1024; n = substr(s, 1, length(s)-1); }
          else if (u == "T") { mult = 1024*1024*1024*1024; n = substr(s, 1, length(s)-1); }
          printf "%.0f", n * mult;
        }')"
      fi

      local zram_dev=""
      local zram_algo=""
      for algo in zstd lz4 lzo-rle ""; do
        if [[ -n "$algo" ]]; then
          zram_dev="$(zramctl --find --size "$size_bytes" --algorithm "$algo" 2>>"$SETUP_LOG" || true)"
          if [[ -n "$zram_dev" ]]; then
            zram_algo="$algo"
            break
          fi
        else
          zram_dev="$(zramctl --find --size "$size_bytes" 2>>"$SETUP_LOG" || true)"
          if [[ -n "$zram_dev" ]]; then
            zram_algo="default"
            break
          fi
        fi
      done

      if [[ -z "$zram_dev" ]]; then
        warn "zramctl failed to allocate a swap device"
        record_status ZRAM_SWAP "failed" "allocation failed"
      else
        if mkswap "$zram_dev" >>"$SETUP_LOG" 2>&1 && swapon -p 100 "$zram_dev" >>"$SETUP_LOG" 2>&1; then
          record_status ZRAM_SWAP "active"
          {
            printf 'ZRAM_DEV=%s\n' "$zram_dev"
            printf 'ZRAM_ALGO=%s\n' "$zram_algo"
            printf 'ZRAM_SIZE=%s\n' "$OVERCLOCK_ZRAM_SWAP_SIZE"
          } >> "$STATE_FILE"

          # Update swappiness to 100 for zram swap
          if [[ -w /proc/sys/vm/swappiness ]]; then
            printf '100' > /proc/sys/vm/swappiness 2>>"$SETUP_LOG" || true
          fi
        else
          warn "mkswap or swapon failed on $zram_dev"
          swapoff "$zram_dev" 2>>"$SETUP_LOG" || true
          zramctl --reset "$zram_dev" 2>>"$SETUP_LOG" || true
          record_status ZRAM_SWAP "failed" "mkswap/swapon failed"
        fi
      fi
    fi
  fi

  # 7. tmpfs-paths
  if [[ -z "$OVERCLOCK_TMPFS_PATHS" ]]; then
    record_status TMPFS_PATHS "disabled"
  elif [[ "$IS_ROOT" != "true" ]]; then
    record_status TMPFS_PATHS "skipped" "non-root"
  else
    local mounted_paths=()
    local size_opt="size=${OVERCLOCK_TMPFS_SIZE:-50%}"
    local paths_array=()
    IFS=',' read -r -a paths_array <<< "$OVERCLOCK_TMPFS_PATHS"

    for target in "${paths_array[@]}"; do
      [[ -n "$target" ]] || continue
      local temp_stage=""
      local has_files=0
      local existed=0

      if [[ -d "$target" ]]; then
        existed=1
        local entries=()
        shopt -s nullglob dotglob
        entries=("$target"/*)
        shopt -u nullglob dotglob
        if [[ ${#entries[@]} -gt 0 ]]; then
          has_files=1
          temp_stage="$(mktemp -d /tmp/overclock-tmpfs-stage.XXXXXX 2>>"$SETUP_LOG" || true)"
          if [[ -n "$temp_stage" && -d "$temp_stage" ]]; then
            cp -a "$target/." "$temp_stage/" 2>>"$SETUP_LOG" || true
          fi
        fi
      else
        # Create missing components owned by the runner user (not root), so
        # e.g. a new ~/.cache stays writable for later steps.
        local missing=() p="$target"
        while [[ -n "$p" && "$p" != "/" && ! -e "$p" ]]; do
          missing=("$p" "${missing[@]}")
          p="$(dirname "$p")"
        done
        for p in "${missing[@]}"; do
          install -d -o "$OVERCLOCK_UID" -g "$OVERCLOCK_GID" "$p" 2>>"$SETUP_LOG" || true
        done
      fi

      # Remember the mount root's original owner/mode. Only the root gets these;
      # copied contents keep their own ownership via cp -a (no recursive chown).
      local root_owner="$OVERCLOCK_UID:$OVERCLOCK_GID"
      local root_mode="0755"
      if [[ "$existed" -eq 1 ]]; then
        root_owner="$(stat -c '%u:%g' "$target" 2>/dev/null || echo "$root_owner")"
        root_mode="$(stat -c '%a' "$target" 2>/dev/null || echo "$root_mode")"
      fi

      if mount -t tmpfs -o "$size_opt" tmpfs "$target" 2>>"$SETUP_LOG"; then
        if [[ "$has_files" -eq 1 && -n "$temp_stage" && -d "$temp_stage" ]]; then
          cp -a "$temp_stage/." "$target/" 2>>"$SETUP_LOG" || true
          rm -rf "$temp_stage" 2>>"$SETUP_LOG" || true
        fi
        chown "$root_owner" "$target" 2>>"$SETUP_LOG" || true
        chmod "$root_mode" "$target" 2>>"$SETUP_LOG" || true
        mounted_paths+=("$target")
      else
        if [[ -n "$temp_stage" && -d "$temp_stage" ]]; then
          rm -rf "$temp_stage" 2>>"$SETUP_LOG" || true
        fi
        warn "Failed to mount tmpfs on $target"
      fi
    done

    if [[ ${#mounted_paths[@]} -gt 0 ]]; then
      local m_str
      m_str=$(IFS=,; echo "${mounted_paths[*]}")
      record_status TMPFS_PATHS "active" "$m_str"
      printf 'TMPFS_MOUNTED=%s\n' "$m_str" >> "$STATE_FILE"
    else
      record_status TMPFS_PATHS "failed" "mount failed"
    fi
  fi

  # 8. Wait for background compile and finalize state
  if [[ -n "$compile_pid" ]]; then
    wait "$compile_pid" 2>>"$SETUP_LOG" || true
  fi

  if [[ "$OVERCLOCK_FSYNC_BYPASS" == "true" ]]; then
    if [[ -n "$compile_result" && -f "$compile_result" ]]; then
      local status=""
      local err=""
      local lib_path=""
      local preload_val=""
      local compile_ms="0"
      local scope=""
      local installed_lib=""
      local orig_preload=""

      while IFS='=' read -r k v || [[ -n "$k" ]]; do
        case "$k" in
          STATUS) status="$v" ;;
          ERR) err="$v" ;;
          LIB_PATH) lib_path="$v" ;;
          LD_PRELOAD_VALUE) preload_val="$v" ;;
          COMPILE_MS) compile_ms="$v" ;;
          PRELOAD_SCOPE) scope="$v" ;;
          INSTALLED_SYSTEM_LIB) installed_lib="$v" ;;
          ORIG_LD_SO_PRELOAD) orig_preload="$v" ;;
        esac
      done < "$compile_result"

      if [[ "$status" == "active" ]]; then
        record_status FSYNC_BYPASS "active"
        {
          printf 'FSYNC_LIB_PATH=%s\n' "$lib_path"
          printf 'LD_PRELOAD_VALUE=%s\n' "$preload_val"
          printf 'FSYNC_COMPILE_MS=%s\n' "$compile_ms"
          printf 'PRELOAD_SCOPE=%s\n' "$scope"
          if [[ -n "$installed_lib" ]]; then
            printf 'INSTALLED_SYSTEM_LIB=%s\n' "$installed_lib"
          fi
          if [[ -n "$orig_preload" ]]; then
            printf 'ORIG_LD_SO_PRELOAD=%s\n' "$orig_preload"
          fi
        } >> "$STATE_FILE"
      else
        warn "libnosync build failed: ${err:-compilation failed}"
        record_status FSYNC_BYPASS "failed" "${err:-compilation failed}"
        printf 'FSYNC_COMPILE_MS=%s\n' "$compile_ms" >> "$STATE_FILE"
      fi
    else
      warn "libnosync build failed: no result produced"
      record_status FSYNC_BYPASS "failed" "no result produced"
      printf 'FSYNC_COMPILE_MS=0\n' >> "$STATE_FILE"
    fi
  else
    record_status FSYNC_BYPASS "disabled"
    printf 'FSYNC_COMPILE_MS=0\n' >> "$STATE_FILE"
  fi

  if [[ -n "$build_tmp" && -d "$build_tmp" ]]; then
    rm -rf "$build_tmp" 2>>"$SETUP_LOG" || true
  fi

  local script_end_ms
  script_end_ms="$(date +%s%3N 2>/dev/null || printf '%s000' "$(date +%s)")"
  local setup_ms=$(( script_end_ms - script_start_ms ))
  {
    printf 'SETUP_SCRIPT_MS=%s\n' "$setup_ms"
    if [[ "$IS_ROOT" == "true" ]]; then
      printf 'PRIVILEGED=true\n'
    else
      printf 'PRIVILEGED=false\n'
    fi
  } >> "$STATE_FILE"

  chown -R "$OVERCLOCK_UID:$OVERCLOCK_GID" "$OVERCLOCK_STATE_DIR" 2>>"$SETUP_LOG" || true
  exit 0
}

# Entrypoint dispatch
TARGET_MODE="${1:-setup}"
case "$TARGET_MODE" in
  setup)
    mode_setup
    ;;
  teardown)
    mode_teardown
    ;;
  *)
    log "Unknown mode '$TARGET_MODE'; running setup"
    mode_setup
    ;;
esac
