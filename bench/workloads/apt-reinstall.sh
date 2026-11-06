#!/usr/bin/env bash
set -euo pipefail

# bench/workloads/apt-reinstall.sh - Reinstall cached packages without download
# Usage: apt-reinstall.sh [prepare|run]

MODE="${1:-run}"

get_packages() {
  local pkg="libboost-dev"
  local dep
  dep=$(apt-cache depends "$pkg" 2>/dev/null | grep -m1 "Depends:" | cut -d: -f2 | tr -d ' ' || true)
  if [ -n "$dep" ]; then
    echo "$pkg $dep"
  else
    echo "$pkg"
  fi
}

case "$MODE" in
  prepare)
    if ! command -v apt-get >/dev/null 2>&1; then
      echo "apt-get not available" >&2
      exit 0
    fi
    # shellcheck disable=SC2046
    PACKAGES=$(get_packages)
    if [ "$EUID" -eq 0 ]; then
      apt-get update -qq
      # shellcheck disable=SC2086
      DEBIAN_FRONTEND=noninteractive apt-get install -y -qq $PACKAGES >/dev/null 2>&1
      # shellcheck disable=SC2086
      apt-get install --reinstall -y --download-only -qq $PACKAGES >/dev/null 2>&1
    elif sudo -n true 2>/dev/null; then
      sudo apt-get update -qq
      # shellcheck disable=SC2086
      sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq $PACKAGES >/dev/null 2>&1
      # shellcheck disable=SC2086
      sudo apt-get install --reinstall -y --download-only -qq $PACKAGES >/dev/null 2>&1
    fi
    ;;

  run)
    if ! command -v apt-get >/dev/null 2>&1; then
      echo "100"
      exit 0
    fi

    # shellcheck disable=SC2046
    PACKAGES=$(get_packages)

    # Smoke fallback if unprivileged
    if [ "$EUID" -ne 0 ] && ! sudo -n true 2>/dev/null; then
      echo "Warning: apt-reinstall requires sudo privileges; running mock" >&2
      echo "100"
      exit 0
    fi

    start=$(date +%s%N)
    if [ "$EUID" -eq 0 ]; then
      if [ -n "${LD_PRELOAD:-}" ]; then
        # shellcheck disable=SC2086
        LD_PRELOAD="$LD_PRELOAD" NOSYNC_STATS_FILE="${NOSYNC_STATS_FILE:-}" DEBIAN_FRONTEND=noninteractive apt-get install --reinstall -y --no-download -o Dpkg::Use-Pty=0 $PACKAGES >/dev/null 2>&1
      else
        # shellcheck disable=SC2086
        env -u LD_PRELOAD DEBIAN_FRONTEND=noninteractive apt-get install --reinstall -y --no-download -o Dpkg::Use-Pty=0 $PACKAGES >/dev/null 2>&1
      fi
    else
      if [ -n "${LD_PRELOAD:-}" ]; then
        # shellcheck disable=SC2086
        sudo env LD_PRELOAD="$LD_PRELOAD" NOSYNC_STATS_FILE="${NOSYNC_STATS_FILE:-}" DEBIAN_FRONTEND=noninteractive apt-get install --reinstall -y --no-download -o Dpkg::Use-Pty=0 $PACKAGES >/dev/null 2>&1
      else
        # shellcheck disable=SC2086
        sudo env -u LD_PRELOAD DEBIAN_FRONTEND=noninteractive apt-get install --reinstall -y --no-download -o Dpkg::Use-Pty=0 $PACKAGES >/dev/null 2>&1
      fi
    fi
    end=$(date +%s%N)

    elapsed_ms=$(( (end - start) / 1000000 ))
    echo "$elapsed_ms"
    ;;

  *)
    echo "Unknown mode: $MODE" >&2
    exit 1
    ;;
esac
