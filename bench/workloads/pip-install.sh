#!/usr/bin/env bash
set -euo pipefail

# bench/workloads/pip-install.sh - pip install offline wheels into fresh venv
# Usage: pip-install.sh [prepare|run]

MODE="${1:-run}"
WORK_DIR="${RUNNER_TEMP:-/tmp}/bench_pip"
WHEEL_DIR="$WORK_DIR/wheels"
VENV_DIR="$WORK_DIR/venv"
PACKAGES=(requests urllib3 rich click pydantic jinja2)

case "$MODE" in
  prepare)
    mkdir -p "$WHEEL_DIR"
    python3 -m pip download --dest "$WHEEL_DIR" "${PACKAGES[@]}" >/dev/null 2>&1
    rm -rf "$VENV_DIR"
    ;;

  run)
    if [ ! -d "$WHEEL_DIR" ] || [ -z "$(ls -A "$WHEEL_DIR" 2>/dev/null)" ]; then
      "$0" prepare
    fi

    rm -rf "$VENV_DIR"
    python3 -m venv "$VENV_DIR"

    start=$(date +%s%N)
    "$VENV_DIR/bin/pip" install --no-index --find-links="$WHEEL_DIR" "${PACKAGES[@]}" >/dev/null 2>&1
    end=$(date +%s%N)

    elapsed_ms=$(( (end - start) / 1000000 ))
    rm -rf "$VENV_DIR"

    echo "$elapsed_ms"
    ;;

  *)
    echo "Unknown mode: $MODE" >&2
    exit 1
    ;;
esac
