#!/usr/bin/env bash
# overclock - Linux root optimization engine
# Modes: setup (default), spill-helper, teardown

set -uo pipefail

OVERCLOCK_ACTION_PATH="${OVERCLOCK_ACTION_PATH:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
OVERCLOCK_FSYNC_BYPASS="${OVERCLOCK_FSYNC_BYPASS:-true}"
OVERCLOCK_PAGE_CACHE="${OVERCLOCK_PAGE_CACHE:-true}"
OVERCLOCK_REMOUNT="${OVERCLOCK_REMOUNT:-true}"
OVERCLOCK_GIT_TUNING="${OVERCLOCK_GIT_TUNING:-true}"
OVERCLOCK_ZRAM="${OVERCLOCK_ZRAM:-false}"
OVERCLOCK_ZRAM_SIZE="${OVERCLOCK_ZRAM_SIZE:-6G}"
OVERCLOCK_SPILL_DIRS="${OVERCLOCK_SPILL_DIRS:-node_modules,.cargo,.gradle,.venv,target}"
OVERCLOCK_WORKSPACE="${OVERCLOCK_WORKSPACE:-$(pwd)}"
OVERCLOCK_UID="${OVERCLOCK_UID:-$(id -u)}"
OVERCLOCK_GID="${OVERCLOCK_GID:-$(id -g)}"
OVERCLOCK_STATE_FILE="${OVERCLOCK_STATE_FILE:-/tmp/overclock-state.env}"
OVERCLOCK_METRICS_FILE="${OVERCLOCK_METRICS_FILE:-/tmp/overclock-metrics-start.env}"
OVERCLOCK_LIB_FALLBACK_DIR="${OVERCLOCK_LIB_FALLBACK_DIR:-/tmp/overclock-lib}"
OVERCLOCK_START_EPOCH_MS="${OVERCLOCK_START_EPOCH_MS:-}"
OVERCLOCK_ARM_MODE="${OVERCLOCK_ARM_MODE:-any_entry}"

IS_ROOT="false"
if [[ "$(id -u)" -eq 0 ]]; then
  IS_ROOT="true"
fi

log() {
  printf '[overclock] %s\n' "$1"
}

warn() {
  printf '::warning title=overclock::%s\n' "$1"
}

state() {
  printf '%s=%s\n' "$1" "$2" >> "$OVERCLOCK_STATE_FILE"
}

bind_spill_dir() {
  local dir="$1"
  local target="$OVERCLOCK_WORKSPACE/$dir"
  local source="/mnt/overclock-spill/$dir"

  if findmnt -rn -o TARGET --mountpoint "$target" >/dev/null 2>&1; then
    return 0
  fi

  if [[ -d "$target" ]]; then
    local entries=()
    shopt -s nullglob dotglob
    entries=("$target"/*)
    shopt -u nullglob dotglob
    if [[ ${#entries[@]} -gt 0 ]]; then
      state "SPILL_SKIPPED" "$dir:non-empty"
      return 0
    fi
  fi

  mkdir -p "$target" 2>/dev/null || true
  chown "$OVERCLOCK_UID:$OVERCLOCK_GID" "$target" 2>/dev/null || true

  local p="$dir"
  while [[ "$p" != "." && "$p" != "/" ]]; do
    p="$(dirname "$p")"
    if [[ "$p" != "." && "$p" != "/" && -d "$OVERCLOCK_WORKSPACE/$p" ]]; then
      chown "$OVERCLOCK_UID:$OVERCLOCK_GID" "$OVERCLOCK_WORKSPACE/$p" 2>/dev/null || true
    fi
  done

  if mount --bind "$source" "$target" 2>/dev/null; then
    state "SPILL_BOUND" "$dir"
  else
    state "SPILL_SKIPPED" "$dir:mount-failed"
  fi
}

mode_spill_helper() {
  echo "$$" > /tmp/overclock-spill-helper.pid 2>/dev/null || true
  local arm_mode="$OVERCLOCK_ARM_MODE"
  local start_time
  start_time="$(date +%s)"
  local armed=0

  local fifo
  fifo="$(mktemp -u /tmp/overclock-helper-fifo.XXXXXX)"
  mkfifo "$fifo" 2>/dev/null || true
  exec 3<>"$fifo" 2>/dev/null || true
  rm -f "$fifo" 2>/dev/null || true

  while true; do
    local now
    now="$(date +%s)"
    local elapsed=$(( now - start_time ))

    if [[ "$elapsed" -ge 3600 ]]; then
      state "SPILL_HELPER" "timeout"
      exec 3>&- 2>/dev/null || true
      exit 0
    fi

    local src
    src="$(findmnt -rn -o SOURCE --mountpoint "$OVERCLOCK_WORKSPACE" 2>/dev/null || true)"
    if [[ ! "$src" =~ ^/dev/zram ]]; then
      exec 3>&- 2>/dev/null || true
      exit 0
    fi

    if [[ "$armed" -eq 0 ]]; then
      if [[ "$arm_mode" == "any_entry" ]]; then
        local entries=()
        shopt -s nullglob dotglob
        entries=("$OVERCLOCK_WORKSPACE"/*)
        shopt -u nullglob dotglob
        if [[ ${#entries[@]} -gt 0 ]]; then
          armed=1
        fi
      elif [[ "$arm_mode" == "git_or_timeout" ]]; then
        if [[ -e "$OVERCLOCK_WORKSPACE/.git" || "$elapsed" -ge 300 ]]; then
          armed=1
        fi
      fi
    fi

    if [[ "$armed" -eq 1 ]]; then
      local spill_array=()
      IFS=',' read -r -a spill_array <<< "$OVERCLOCK_SPILL_DIRS"
      for dir in "${spill_array[@]}"; do
        [[ -n "$dir" ]] || continue
        bind_spill_dir "$dir"
      done
      state "SPILL_HELPER" "done"
      exec 3>&- 2>/dev/null || true
      exit 0
    fi

    if [[ "$elapsed" -lt 600 ]]; then
      read -r -t 0.05 -u 3 _ 2>/dev/null || true
    else
      read -r -t 1 -u 3 _ 2>/dev/null || true
    fi
  done
}

mode_teardown() {
  log "Teardown initiated"

  local helper_pid=""
  if [[ -f /tmp/overclock-spill-helper.pid ]]; then
    read -r helper_pid < /tmp/overclock-spill-helper.pid 2>/dev/null || true
  fi
  if [[ -n "$helper_pid" ]]; then
    if kill -0 "$helper_pid" 2>/dev/null; then
      kill -TERM "$helper_pid" 2>/dev/null || true
      sleep 0.05 2>/dev/null || true
      if kill -0 "$helper_pid" 2>/dev/null; then
        kill -9 "$helper_pid" 2>/dev/null || true
      fi
    fi
    rm -f /tmp/overclock-spill-helper.pid 2>/dev/null || true
  fi

  local bound_dirs=()
  local zram_dev=""
  local orig_sysctl=""
  if [[ -f "$OVERCLOCK_STATE_FILE" ]]; then
    while IFS='=' read -r k v || [[ -n "$k" ]]; do
      case "$k" in
        SPILL_BOUND) bound_dirs+=("$v") ;;
        ZRAM_DEV) zram_dev="$v" ;;
        ORIG_SYSCTL) orig_sysctl="$v" ;;
      esac
    done < "$OVERCLOCK_STATE_FILE"
  fi

  for dir in "${bound_dirs[@]}"; do
    [[ -n "$dir" ]] || continue
    umount -l "$OVERCLOCK_WORKSPACE/$dir" 2>/dev/null || true
  done

  local src
  src="$(findmnt -rn -o SOURCE --mountpoint "$OVERCLOCK_WORKSPACE" 2>/dev/null || true)"
  if [[ "$src" =~ ^/dev/zram ]]; then
    umount -l "$OVERCLOCK_WORKSPACE" 2>/dev/null || true
  fi

  if [[ -n "$zram_dev" && -b "$zram_dev" ]]; then
    zramctl --reset "$zram_dev" 2>/dev/null || true
  fi

  if [[ -n "$orig_sysctl" ]]; then
    local pairs=()
    IFS=',' read -r -a pairs <<< "$orig_sysctl"
    for pair in "${pairs[@]}"; do
      local k="${pair%%:*}"
      local v="${pair#*:}"
      local p="/proc/sys/${k//.//}"
      if [[ -w "$p" ]]; then
        printf '%s' "$v" > "$p" 2>/dev/null || true
      fi
    done
  fi

  log "Teardown complete"
  exit 0
}

mode_setup() {
  local script_start_ms
  script_start_ms="$(date +%s%3N 2>/dev/null || printf '%s000' "$(date +%s)")"

  # Truncate and prep state file
  : > "$OVERCLOCK_STATE_FILE"
  chmod 0644 "$OVERCLOCK_STATE_FILE" 2>/dev/null || true

  # 1. Baseline telemetry -> metrics file
  : > "$OVERCLOCK_METRICS_FILE"
  chmod 0644 "$OVERCLOCK_METRICS_FILE" 2>/dev/null || true

  local start_epoch="$OVERCLOCK_START_EPOCH_MS"
  if [[ -z "$start_epoch" ]]; then
    start_epoch="$(date +%s%3N 2>/dev/null || printf '%s000' "$(date +%s)")"
  fi
  printf 'START_EPOCH_MS=%s\n' "$start_epoch" >> "$OVERCLOCK_METRICS_FILE"

  local start_uptime="0"
  if [[ -r /proc/uptime ]]; then
    read -r start_uptime _ < /proc/uptime || true
  fi
  printf 'START_UPTIME=%s\n' "$start_uptime" >> "$OVERCLOCK_METRICS_FILE"

  local cpu_stat=""
  if [[ -r /proc/stat ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
      if [[ "$line" =~ ^cpu[[:space:]]+(.*)$ ]]; then
        cpu_stat="${BASH_REMATCH[1]}"
        break
      fi
    done < /proc/stat
  fi
  printf 'CPU_STAT=%s\n' "$cpu_stat" >> "$OVERCLOCK_METRICS_FILE"

  if [[ -r /proc/vmstat ]]; then
    awk '$1 ~ /^(pgpgin|pgpgout|pswpin|pswpout|nr_dirtied|nr_written|pgmajfault|oom_kill)$/ { print "VMSTAT_" $1 "=" $2 }' /proc/vmstat >> "$OVERCLOCK_METRICS_FILE" || true
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
  printf 'DISK_DEVICES=%s\n' "$disk_devs" >> "$OVERCLOCK_METRICS_FILE"

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
    }' /proc/diskstats >> "$OVERCLOCK_METRICS_FILE" || true
  else
    printf 'DISK_READ_IOS=0\nDISK_READ_SECTORS=0\nDISK_WRITE_IOS=0\nDISK_WRITE_SECTORS=0\nDISK_IO_TICKS_MS=0\n' >> "$OVERCLOCK_METRICS_FILE"
  fi

  # 2. Background libnosync build
  local compile_pid=""
  local build_tmp=""
  local compile_result=""

  if [[ "$OVERCLOCK_FSYNC_BYPASS" == "true" ]]; then
    build_tmp="$(mktemp -d /tmp/overclock-build.XXXXXX 2>/dev/null || true)"
    if [[ -n "$build_tmp" && -d "$build_tmp" ]]; then
      compile_result="$build_tmp/result.env"
      local nosync_src="$OVERCLOCK_ACTION_PATH/src/nosync.c"
      if [[ -r "$nosync_src" ]]; then
        cp "$nosync_src" "$build_tmp/nosync.c" 2>/dev/null || true
      fi

      (
        local t_cstart
        t_cstart="$(date +%s%3N 2>/dev/null || printf '%s000' "$(date +%s)")"

        if [[ ! -r "$build_tmp/nosync.c" ]]; then
          local t_cend
          t_cend="$(date +%s%3N 2>/dev/null || printf '%s000' "$(date +%s)")"
          cat <<EOF > "$compile_result"
STATUS=failed
ERR=nosync.c not found
COMPILE_MS=$(( t_cend - t_cstart ))
EOF
          exit 0
        fi

        if ! command -v gcc >/dev/null 2>&1; then
          local t_cend
          t_cend="$(date +%s%3N 2>/dev/null || printf '%s000' "$(date +%s)")"
          cat <<EOF > "$compile_result"
STATUS=failed
ERR=gcc not found
COMPILE_MS=$(( t_cend - t_cstart ))
EOF
          exit 0
        fi

        local tmp_so="$build_tmp/libnosync.so"
        if ! gcc -O2 -shared -fPIC -U_FORTIFY_SOURCE -D_GNU_SOURCE -Wall -o "$tmp_so" "$build_tmp/nosync.c" -ldl; then
          local t_cend
          t_cend="$(date +%s%3N 2>/dev/null || printf '%s000' "$(date +%s)")"
          cat <<EOF > "$compile_result"
STATUS=failed
ERR=gcc compilation failed
COMPILE_MS=$(( t_cend - t_cstart ))
EOF
          exit 0
        fi

        if [[ "$IS_ROOT" == "true" ]]; then
          mkdir -p /usr/local/lib 2>/dev/null || true
          if ! install -m 0755 "$tmp_so" /usr/local/lib/libnosync.so 2>/dev/null; then
            local t_cend
            t_cend="$(date +%s%3N 2>/dev/null || printf '%s000' "$(date +%s)")"
            cat <<EOF > "$compile_result"
STATUS=failed
ERR=install to /usr/local/lib failed
COMPILE_MS=$(( t_cend - t_cstart ))
EOF
            exit 0
          fi

          local triplet
          triplet="$(gcc -dumpmachine 2>/dev/null || true)"
          if [[ -n "$triplet" && -d "/usr/lib/$triplet" ]]; then
            install -m 4755 "$tmp_so" "/usr/lib/$triplet/libnosync.so" 2>/dev/null || true
          fi

          mkdir -p /etc/ld.so.conf.d 2>/dev/null || true
          printf '/usr/local/lib\n' > /etc/ld.so.conf.d/nosync.conf 2>/dev/null || true
          setsid ldconfig </dev/null >/dev/null 2>&1 &

          local t_cend
          t_cend="$(date +%s%3N 2>/dev/null || printf '%s000' "$(date +%s)")"
          cat <<EOF > "$compile_result"
STATUS=active
LIB_PATH=/usr/local/lib/libnosync.so
LD_PRELOAD_VALUE=libnosync.so
COMPILE_MS=$(( t_cend - t_cstart ))
EOF
        else
          mkdir -p "$OVERCLOCK_LIB_FALLBACK_DIR" 2>/dev/null || true
          if ! install -m 0755 "$tmp_so" "$OVERCLOCK_LIB_FALLBACK_DIR/libnosync.so" 2>/dev/null; then
            local t_cend
            t_cend="$(date +%s%3N 2>/dev/null || printf '%s000' "$(date +%s)")"
            cat <<EOF > "$compile_result"
STATUS=failed
ERR=install to fallback dir failed
COMPILE_MS=$(( t_cend - t_cstart ))
EOF
            exit 0
          fi

          local t_cend
          t_cend="$(date +%s%3N 2>/dev/null || printf '%s000' "$(date +%s)")"
          cat <<EOF > "$compile_result"
STATUS=active
LIB_PATH=$OVERCLOCK_LIB_FALLBACK_DIR/libnosync.so
LD_PRELOAD_VALUE=$OVERCLOCK_LIB_FALLBACK_DIR/libnosync.so
COMPILE_MS=$(( t_cend - t_cstart ))
EOF
        fi
      ) >"$build_tmp/compile.log" 2>&1 &
      compile_pid=$!
    else
      warn "failed to create temp dir for libnosync build"
    fi
  fi

  # 3. Bloat suppression, CPU governor, and block queue optimizations
  systemctl stop --no-block apt-daily.timer apt-daily-upgrade.timer fstrim.timer sysstat.timer unattended-upgrades.service multipathd.service multipathd.socket 2>/dev/null || true

  for gov in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
    [[ -w "$gov" ]] && printf 'performance' > "$gov" 2>/dev/null || true
  done

  for b in /sys/block/*; do
    [[ -e "$b" ]] || continue
    case "${b##*/}" in
      loop*|ram*|zram*|sr*|fd*|nbd*) continue ;;
    esac
    [[ -w "$b/queue/scheduler" ]] && echo none > "$b/queue/scheduler" 2>/dev/null || true
    [[ -w "$b/queue/nr_requests" ]] && echo 512 > "$b/queue/nr_requests" 2>/dev/null || true
    [[ -w "$b/queue/rq_affinity" ]] && echo 2 > "$b/queue/rq_affinity" 2>/dev/null || true
    [[ -w "$b/queue/add_random" ]] && echo 0 > "$b/queue/add_random" 2>/dev/null || true
    [[ -w "$b/queue/rotational" ]] && echo 0 > "$b/queue/rotational" 2>/dev/null || true
  done

  # 4. Page cache and sysctl tuning
  if [[ "$OVERCLOCK_PAGE_CACHE" != "true" ]]; then
    state PAGE_CACHE "disabled"
  elif [[ "$IS_ROOT" != "true" ]]; then
    state PAGE_CACHE "skipped"
  else
    local sysctl_keys=(
      "vm.dirty_ratio"
      "vm.dirty_background_ratio"
      "vm.dirty_expire_centisecs"
      "vm.dirty_writeback_centisecs"
      "vm.swappiness"
      "fs.inotify.max_user_watches"
      "kernel.sched_migration_cost_ns"
      "kernel.sched_autogroup_enabled"
      "kernel.numa_balancing"
      "vm.overcommit_memory"
      "vm.vfs_cache_pressure"
      "fs.file-max"
      "net.core.somaxconn"
      "net.ipv4.tcp_max_syn_backlog"
      "net.ipv4.tcp_tw_reuse"
      "net.ipv4.ip_local_port_range"
      "net.ipv4.tcp_fin_timeout"
      "net.core.netdev_max_backlog"
      "net.core.rmem_max"
      "net.core.wmem_max"
      "net.ipv4.tcp_rmem"
      "net.ipv4.tcp_wmem"
      "net.ipv4.tcp_fastopen"
    )
    local sysctl_vals=(
      "80"
      "50"
      "60000"
      "6000"
      "10"
      "1048576"
      "5000000"
      "0"
      "0"
      "1"
      "50"
      "2097152"
      "65535"
      "65535"
      "1"
      "1024 65535"
      "15"
      "10000"
      "16777216"
      "16777216"
      "4096 87380 16777216"
      "4096 65536 16777216"
      "3"
    )

    local orig_pairs=()
    for k in "${sysctl_keys[@]}"; do
      local p="/proc/sys/${k//.//}"
      if [[ -r "$p" ]]; then
        local cur_val=""
        read -r cur_val < "$p" 2>/dev/null || cur_val=""
        orig_pairs+=("$k:$cur_val")
      fi
    done
    if [[ ${#orig_pairs[@]} -gt 0 ]]; then
      local orig_str
      orig_str=$(IFS=,; echo "${orig_pairs[*]}")
      state ORIG_SYSCTL "$orig_str"
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
      if printf '%s' "$v" > "$p" 2>/dev/null; then
        ((success_cnt++)) || true
      else
        ((fail_cnt++)) || true
      fi
    done

    # THP defrag
    [[ -w /sys/kernel/mm/transparent_hugepage/defrag ]] && echo 'defer+madvise' > /sys/kernel/mm/transparent_hugepage/defrag 2>/dev/null || true

    # TCP BBR congestion control
    modprobe tcp_bbr 2>/dev/null || true
    sysctl -w net.core.default_qdisc=fq net.ipv4.tcp_congestion_control=bbr >/dev/null 2>&1 || true

    if [[ "$fail_cnt" -eq 0 ]]; then
      state PAGE_CACHE "active"
    elif [[ "$success_cnt" -gt 0 ]]; then
      state PAGE_CACHE "partial"
    else
      state PAGE_CACHE "failed"
    fi
  fi

  # 5. Remount
  if [[ "$OVERCLOCK_REMOUNT" != "true" ]]; then
    state REMOUNT "disabled"
  elif [[ "$IS_ROOT" != "true" ]]; then
    state REMOUNT "skipped"
  else
    local remount_details=()
    local any_active=0
    local any_partial=0
    local any_failed=0
    local any_ext4=0

    for mp in / /mnt; do
      local fstype
      fstype="$(findmnt -rn -o FSTYPE --mountpoint "$mp" 2>/dev/null || true)"
      if [[ -z "$fstype" ]]; then
        remount_details+=("$mp:absent")
      elif [[ "$fstype" != "ext4" ]]; then
        remount_details+=("$mp:not-ext4:$fstype")
      else
        any_ext4=1
        if mount -o remount,noatime,nodiratime,barrier=0,commit=600 "$mp" 2>/dev/null; then
          remount_details+=("$mp:ok")
          any_active=1
        elif mount -o remount,noatime,commit=600 "$mp" 2>/dev/null; then
          remount_details+=("$mp:partial")
          any_partial=1
        else
          remount_details+=("$mp:failed")
          any_failed=1
        fi
      fi
    done

    local remount_status="skipped"
    if [[ "$any_ext4" -eq 1 ]]; then
      if [[ "$any_failed" -eq 1 && "$any_active" -eq 0 && "$any_partial" -eq 0 ]]; then
        remount_status="failed"
      elif [[ "$any_partial" -eq 1 || "$any_failed" -eq 1 ]]; then
        remount_status="partial"
      else
        remount_status="active"
      fi
    fi

    local detail_str
    detail_str=$(IFS=';'; echo "${remount_details[*]}")
    state REMOUNT "$remount_status"
    state REMOUNT_DETAIL "$detail_str"
  fi

  # 6. zram workspace
  local zram_active=0
  local arm_mode="any_entry"
  local ws_had_files=0
  local ws_had_git=0

  if [[ "$OVERCLOCK_ZRAM" != "true" ]]; then
    state ZRAM "disabled"
    state ZRAM_DEV ""
    state ZRAM_SIZE ""
    state ZRAM_ALGO ""
    state ZRAM_DETAIL ""
  elif [[ "$IS_ROOT" != "true" ]]; then
    warn "zram workspace requires root privileges; skipping"
    state ZRAM "skipped"
    state ZRAM_DEV ""
    state ZRAM_SIZE ""
    state ZRAM_ALGO ""
    state ZRAM_DETAIL "requires root"
  else
    local existing_src
    existing_src="$(findmnt -rn -o SOURCE --mountpoint "$OVERCLOCK_WORKSPACE" 2>/dev/null || true)"
    if [[ "$existing_src" =~ ^/dev/zram ]]; then
      state ZRAM "active"
      state ZRAM_DEV "$existing_src"
      state ZRAM_SIZE ""
      state ZRAM_ALGO ""
      state ZRAM_DETAIL "reused existing mount"
      zram_active=1
    else
      # Check size vs physical memory
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
        local zram_bytes
        zram_bytes="$(awk -v s="$OVERCLOCK_ZRAM_SIZE" 'BEGIN {
          u = toupper(substr(s, length(s)));
          n = s;
          mult = 1;
          if (u == "K") { mult = 1024; n = substr(s, 1, length(s)-1); }
          else if (u == "M") { mult = 1024*1024; n = substr(s, 1, length(s)-1); }
          else if (u == "G") { mult = 1024*1024*1024; n = substr(s, 1, length(s)-1); }
          else if (u == "T") { mult = 1024*1024*1024*1024; n = substr(s, 1, length(s)-1); }
          printf "%.0f", n * mult;
        }')"
        local mem_limit_bytes=$(( mem_total_kb * 1024 * 2 ))
        if [[ "$zram_bytes" -gt "$mem_limit_bytes" ]]; then
          warn "zram size ($OVERCLOCK_ZRAM_SIZE) exceeds 2x physical RAM"
        fi
      fi

      modprobe zram 2>/dev/null || true
      if [[ ! -e /sys/class/zram-control && ! -e /dev/zram0 ]]; then
        warn "zram kernel module not available or unsupported in this kernel"
        state ZRAM "unsupported"
        state ZRAM_DEV ""
        state ZRAM_SIZE ""
        state ZRAM_ALGO ""
        state ZRAM_DETAIL "unsupported kernel"
      else
        local zram_dev=""
        local zram_algo=""
        for algo in lz4 lzo-rle ""; do
          if [[ -n "$algo" ]]; then
            zram_dev="$(zramctl --find --size "$OVERCLOCK_ZRAM_SIZE" --algorithm "$algo" 2>/dev/null || true)"
            if [[ -n "$zram_dev" ]]; then
              zram_algo="$algo"
              break
            fi
          else
            zram_dev="$(zramctl --find --size "$OVERCLOCK_ZRAM_SIZE" 2>/dev/null || true)"
            if [[ -n "$zram_dev" ]]; then
              zram_algo="default"
              break
            fi
          fi
        done

        if [[ -z "$zram_dev" ]]; then
          warn "zramctl failed to allocate a zram device"
          state ZRAM "failed"
          state ZRAM_DEV ""
          state ZRAM_SIZE ""
          state ZRAM_ALGO ""
          state ZRAM_DETAIL "allocation failed"
        else
          if ! mkfs.ext4 -q -F -m 0 -O ^has_journal -E discard "$zram_dev" 2>/dev/null; then
            warn "mkfs.ext4 failed on $zram_dev"
            zramctl --reset "$zram_dev" 2>/dev/null || true
            state ZRAM "failed"
            state ZRAM_DEV ""
            state ZRAM_SIZE ""
            state ZRAM_ALGO ""
            state ZRAM_DETAIL "mkfs.ext4 failed"
          else
            local preserve_dir=""
            if [[ -d "$OVERCLOCK_WORKSPACE" ]]; then
              if [[ -e "$OVERCLOCK_WORKSPACE/.git" ]]; then
                ws_had_git=1
              fi
              local ws_items=()
              shopt -s nullglob dotglob
              ws_items=("$OVERCLOCK_WORKSPACE"/*)
              shopt -u nullglob dotglob
              if [[ ${#ws_items[@]} -gt 0 ]]; then
                ws_had_files=1
                preserve_dir="$(dirname "$OVERCLOCK_WORKSPACE")/.overclock-preserve.$$"
                mkdir -p "$preserve_dir" 2>/dev/null || true
                find "$OVERCLOCK_WORKSPACE" -mindepth 1 -maxdepth 1 -exec mv -t "$preserve_dir" -- {} + 2>/dev/null || true
              fi
            fi

            mkdir -p "$OVERCLOCK_WORKSPACE" 2>/dev/null || true
            if ! mount -o noatime,barrier=0,discard "$zram_dev" "$OVERCLOCK_WORKSPACE" 2>/dev/null; then
              warn "mount of $zram_dev on $OVERCLOCK_WORKSPACE failed"
              if [[ "$ws_had_files" -eq 1 && -n "$preserve_dir" && -d "$preserve_dir" ]]; then
                cp -a "$preserve_dir/." "$OVERCLOCK_WORKSPACE/" 2>/dev/null || true
                rm -rf "$preserve_dir" 2>/dev/null || true
              fi
              zramctl --reset "$zram_dev" 2>/dev/null || true
              state ZRAM "failed"
              state ZRAM_DEV ""
              state ZRAM_SIZE ""
              state ZRAM_ALGO ""
              state ZRAM_DETAIL "mount failed"
            else
              rmdir "$OVERCLOCK_WORKSPACE/lost+found" 2>/dev/null || true
              if [[ "$ws_had_files" -eq 1 && -n "$preserve_dir" && -d "$preserve_dir" ]]; then
                cp -a "$preserve_dir/." "$OVERCLOCK_WORKSPACE/" 2>/dev/null || true
                rm -rf "$preserve_dir" 2>/dev/null || true
                chown -R "$OVERCLOCK_UID:$OVERCLOCK_GID" "$OVERCLOCK_WORKSPACE" 2>/dev/null || true
              else
                chown "$OVERCLOCK_UID:$OVERCLOCK_GID" "$OVERCLOCK_WORKSPACE" 2>/dev/null || true
              fi

              state ZRAM "active"
              state ZRAM_DEV "$zram_dev"
              state ZRAM_SIZE "$OVERCLOCK_ZRAM_SIZE"
              state ZRAM_ALGO "$zram_algo"
              state ZRAM_DETAIL "mounted"
              zram_active=1
            fi
          fi
        fi
      fi
    fi
  fi

  # Determine arm mode for spill helper
  if [[ "$ws_had_files" -eq 0 ]]; then
    arm_mode="any_entry"
  elif [[ "$ws_had_git" -eq 0 ]]; then
    arm_mode="git_or_timeout"
  else
    arm_mode="immediate"
  fi

  # 7. Spill dirs
  if [[ "$zram_active" -eq 1 && -n "$OVERCLOCK_SPILL_DIRS" ]]; then
    local spill_array=()
    IFS=',' read -r -a spill_array <<< "$OVERCLOCK_SPILL_DIRS"
    for dir in "${spill_array[@]}"; do
      [[ -n "$dir" ]] || continue
      mkdir -p "/mnt/overclock-spill/$dir" 2>/dev/null || true
      chown -R "$OVERCLOCK_UID:$OVERCLOCK_GID" "/mnt/overclock-spill/$dir" 2>/dev/null || true
    done
    chown "$OVERCLOCK_UID:$OVERCLOCK_GID" /mnt/overclock-spill 2>/dev/null || true

    if [[ "$arm_mode" == "immediate" ]]; then
      warn "workspace is non-empty with existing .git; binding spill dirs immediately (actions/checkout with clean: true may conflict)"
      state SPILL_DIRS "$OVERCLOCK_SPILL_DIRS"
      state SPILL_MODE "immediate"
      state SPILL_HELPER_PID ""
      for dir in "${spill_array[@]}"; do
        [[ -n "$dir" ]] || continue
        bind_spill_dir "$dir"
      done
    else
      state SPILL_DIRS "$OVERCLOCK_SPILL_DIRS"
      state SPILL_MODE "deferred"
      export OVERCLOCK_WORKSPACE OVERCLOCK_SPILL_DIRS OVERCLOCK_STATE_FILE OVERCLOCK_UID OVERCLOCK_GID OVERCLOCK_ARM_MODE="$arm_mode"
      setsid "$0" spill-helper </dev/null >>/tmp/overclock-spill-helper.log 2>&1 &
      local helper_pid=$!
      echo "$helper_pid" > /tmp/overclock-spill-helper.pid 2>/dev/null || true
      state SPILL_HELPER_PID "$helper_pid"
    fi
  else
    state SPILL_DIRS "$OVERCLOCK_SPILL_DIRS"
    state SPILL_MODE "none"
    state SPILL_HELPER_PID ""
  fi

  # 8. Git tuning
  if [[ "$OVERCLOCK_GIT_TUNING" != "true" ]]; then
    state GIT_TUNING "disabled"
  elif ! command -v git >/dev/null 2>&1; then
    state GIT_TUNING "failed"
  else
    local scope_flag="--global"
    local scope_name="global"
    if [[ "$IS_ROOT" == "true" ]]; then
      scope_flag="--system"
      scope_name="system"
    fi

    local git_kvs=(
      "feature.manyFiles:true"
      "core.untrackedCache:true"
      "core.fscache:true"
      "pack.threads:0"
      "index.threads:true"
      "checkout.workers:0"
      "fetch.parallel:0"
      "submodule.fetchJobs:0"
      "gc.auto:0"
      "maintenance.auto:false"
      "index.skipHash:false"
    )

    local git_failed=0
    for kv in "${git_kvs[@]}"; do
      local k="${kv%%:*}"
      local v="${kv#*:}"
      if ! git config "$scope_flag" "$k" "$v" 2>/dev/null; then
        git_failed=1
      fi
    done

    if [[ "$git_failed" -eq 0 ]]; then
      state GIT_TUNING "$scope_name"
    else
      warn "git config tuning failed on scope $scope_name"
      state GIT_TUNING "failed"
    fi
  fi

  # 9. Wait for background compile and finalize state
  if [[ -n "$compile_pid" ]]; then
    wait "$compile_pid" 2>/dev/null || true
  fi

  if [[ "$OVERCLOCK_FSYNC_BYPASS" == "true" ]]; then
    if [[ -n "$compile_result" && -f "$compile_result" ]]; then
      local status=""
      local err=""
      local lib_path=""
      local preload_val=""
      local compile_ms="0"

      while IFS='=' read -r k v || [[ -n "$k" ]]; do
        case "$k" in
          STATUS) status="$v" ;;
          ERR) err="$v" ;;
          LIB_PATH) lib_path="$v" ;;
          LD_PRELOAD_VALUE) preload_val="$v" ;;
          COMPILE_MS) compile_ms="$v" ;;
        esac
      done < "$compile_result"

      if [[ "$status" == "active" ]]; then
        state FSYNC_BYPASS "active"
        state FSYNC_LIB_PATH "$lib_path"
        state LD_PRELOAD_VALUE "$preload_val"
        state FSYNC_COMPILE_MS "$compile_ms"
      else
        warn "libnosync build failed: ${err:-compilation failed}"
        state FSYNC_BYPASS "failed"
        state FSYNC_LIB_PATH ""
        state LD_PRELOAD_VALUE ""
        state FSYNC_COMPILE_MS "$compile_ms"
      fi
    else
      warn "libnosync build failed: no result produced"
      state FSYNC_BYPASS "failed"
      state FSYNC_LIB_PATH ""
      state LD_PRELOAD_VALUE ""
      state FSYNC_COMPILE_MS "0"
    fi
  else
    state FSYNC_BYPASS "disabled"
    state FSYNC_LIB_PATH ""
    state LD_PRELOAD_VALUE ""
    state FSYNC_COMPILE_MS "0"
  fi

  if [[ -n "$build_tmp" && -d "$build_tmp" ]]; then
    rm -rf "$build_tmp" 2>/dev/null || true
  fi

  local script_end_ms
  script_end_ms="$(date +%s%3N 2>/dev/null || printf '%s000' "$(date +%s)")"
  local setup_ms=$(( script_end_ms - script_start_ms ))
  state SETUP_SCRIPT_MS "$setup_ms"

  if [[ "$IS_ROOT" == "true" ]]; then
    state PRIVILEGED "true"
  else
    state PRIVILEGED "false"
  fi

  exit 0
}

# Entrypoint dispatch
TARGET_MODE="${1:-setup}"
case "$TARGET_MODE" in
  setup)
    mode_setup
    ;;
  spill-helper)
    mode_spill_helper
    ;;
  teardown)
    mode_teardown
    ;;
  *)
    log "Unknown mode '$TARGET_MODE'; running setup"
    mode_setup
    ;;
esac
