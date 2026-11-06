#!/usr/bin/env bash
set -euo pipefail

# bench/workloads/smallfiles.sh - Extract 30,000 files + git init/add/commit + rm -rf
# Usage: smallfiles.sh [prepare|run]

MODE="${1:-run}"
WORK_DIR="${RUNNER_TEMP:-/tmp}/bench_smallfiles"
TAR_PATH="$WORK_DIR/smallfiles_30k.tar"
TREE_DIR="$WORK_DIR/tree"

case "$MODE" in
  prepare)
    mkdir -p "$WORK_DIR"
    if [ ! -f "$TAR_PATH" ]; then
      python3 - "$TAR_PATH" <<'PY'
import io
import os
import sys
import tarfile

tar_path = sys.argv[1]
payloads = [os.urandom(sz) for sz in range(200, 2001, 100)]
num_payloads = len(payloads)

with tarfile.open(tar_path, "w") as tar:
    for i in range(30000):
        dir_idx = i % 300
        data = payloads[i % num_payloads]
        ti = tarfile.TarInfo(name=f"dir_{dir_idx:03d}/file_{i:05d}.dat")
        ti.size = len(data)
        ti.mtime = 1700000000
        ti.mode = 0o644
        tar.addfile(ti, io.BytesIO(data))
PY
    fi
    rm -rf "$TREE_DIR"
    ;;

  run)
    if [ ! -f "$TAR_PATH" ]; then
      "$0" prepare
    fi

    rm -rf "$TREE_DIR"
    mkdir -p "$TREE_DIR"

    start=$(date +%s%N)

    tar -xf "$TAR_PATH" -C "$TREE_DIR"
    (
      cd "$TREE_DIR"
      git init -q
      git config user.name "bench"
      git config user.email "bench@example.com"
      git add -A
      git commit -q -m "bench"
    )
    rm -rf "$TREE_DIR"

    end=$(date +%s%N)
    elapsed_ms=$(( (end - start) / 1000000 ))

    echo "$elapsed_ms"
    ;;

  *)
    echo "Unknown mode: $MODE" >&2
    exit 1
    ;;
esac
