#!/usr/bin/env bash
set -euo pipefail

# bench/run.sh - Orchestrate interleaved A/B benchmark for a single workload
# Usage: bench/run.sh <workload> <reps> <out.json>

WORKLOAD="${1:-}"
REPS="${2:-5}"
OUT_JSON="${3:-results/${WORKLOAD}.json}"

if [ -z "$WORKLOAD" ]; then
  echo "Usage: $0 <workload> [reps] [out.json]" >&2
  exit 1
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKLOAD_SCRIPT="$REPO_ROOT/bench/workloads/${WORKLOAD}.sh"

if [ ! -f "$WORKLOAD_SCRIPT" ]; then
  echo "Error: workload script not found: $WORKLOAD_SCRIPT" >&2
  exit 1
fi

RUNNER_TEMP="${RUNNER_TEMP:-/tmp}"
LIBNOSYNC="$RUNNER_TEMP/libnosync.so"

echo "=== Building libnosync.so ==="
gcc -O2 -shared -fPIC -pthread -U_FORTIFY_SOURCE -D_GNU_SOURCE -Wall -o "$LIBNOSYNC" "$REPO_ROOT/src/nosync.c" -ldl

echo "=== Preparing workload: $WORKLOAD (untimed) ==="
bash "$WORKLOAD_SCRIPT" prepare

CONFIGS=("baseline" "fsync" "kernel" "all")
NUM_CONFIGS=${#CONFIGS[@]}

RAW_RESULTS_FILE="$RUNNER_TEMP/bench_raw_${WORKLOAD}_$$.txt"
rm -f "$RAW_RESULTS_FILE"

apply_knobs() {
  local cfg="$1"
  if [ "$EUID" -eq 0 ]; then
    bash "$REPO_ROOT/bench/knobs.sh" "$cfg"
  elif sudo -n true 2>/dev/null; then
    sudo bash "$REPO_ROOT/bench/knobs.sh" "$cfg" 2>/dev/null || true
  fi
}

drop_caches() {
  sync
  if [ "$EUID" -eq 0 ]; then
    echo 3 > /proc/sys/vm/drop_caches 2>/dev/null || true
  elif sudo -n true 2>/dev/null; then
    echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null 2>/dev/null || true
  fi
}

echo "=== Running interleaved benchmark: $WORKLOAD ($REPS reps x $NUM_CONFIGS configs) ==="

for ((r=0; r<REPS; r++)); do
  for ((i=0; i<NUM_CONFIGS; i++)); do
    cfg_idx=$(( (i + r) % NUM_CONFIGS ))
    cfg="${CONFIGS[$cfg_idx]}"

    # 1. Apply knobs
    apply_knobs "$cfg"

    # 2. Drop page cache (untimed)
    drop_caches

    # 3. Setup iteration stats file
    iter_stats="$RUNNER_TEMP/nosync_stats_${WORKLOAD}_${cfg}_${r}_${i}.log"
    rm -f "$iter_stats"
    touch "$iter_stats"
    chmod 0666 "$iter_stats" 2>/dev/null || true

    # 4. Run workload iteration
    raw_output=""
    if [ "$cfg" = "fsync" ] || [ "$cfg" = "all" ]; then
      raw_output=$(env LD_PRELOAD="$LIBNOSYNC" NOSYNC_STATS_FILE="$iter_stats" bash "$WORKLOAD_SCRIPT" run)
    else
      raw_output=$(env -u LD_PRELOAD -u NOSYNC_STATS_FILE bash "$WORKLOAD_SCRIPT" run)
    fi

    # Parse elapsed ms from the last line of output
    elapsed_ms=$(echo "$raw_output" | tail -n 1 | tr -d '\r')

    # 5. Extract skipped fsyncs count
    iter_skipped=0
    if [ -f "$iter_stats" ]; then
      iter_skipped=$(awk '{s+=$2} END {print s+0}' "$iter_stats" 2>/dev/null || echo 0)
      rm -f "$iter_stats"
    fi

    echo "  Rep $((r + 1))/$REPS | Config: $cfg | Time: ${elapsed_ms} ms | Skipped fsyncs: $iter_skipped"
    echo "$cfg $elapsed_ms $iter_skipped" >> "$RAW_RESULTS_FILE"
  done
done

# Restore baseline knobs
apply_knobs "baseline"

echo "=== Generating benchmark results JSON ==="
python3 - "$WORKLOAD" "$REPS" "$OUT_JSON" "$RAW_RESULTS_FILE" <<'PY'
import json
import os
import sys

workload = sys.argv[1]
reps = int(sys.argv[2])
out_path = sys.argv[3]
raw_file = sys.argv[4]

runner = os.environ.get("BENCH_RUNNER") or os.environ.get("RUNNER_NAME") or "local"
arch = os.uname().machine

results = {"baseline": [], "fsync": [], "kernel": [], "all": []}
skipped_fsyncs = {"baseline": 0, "fsync": 0, "kernel": 0, "all": 0}

if os.path.exists(raw_file):
    with open(raw_file, "r", encoding="utf-8") as f:
        for line in f:
            parts = line.strip().split()
            if len(parts) >= 3:
                cfg, ms_str, sk_str = parts[0], parts[1], parts[2]
                if cfg in results:
                    try:
                        results[cfg].append(float(ms_str))
                        skipped_fsyncs[cfg] += int(sk_str)
                    except ValueError:
                        pass

data = {
    "workload": workload,
    "runner": runner,
    "arch": arch,
    "reps": reps,
    "results": results,
    "skipped_fsyncs": skipped_fsyncs,
}

os.makedirs(os.path.dirname(os.path.abspath(out_path)), exist_ok=True)
with open(out_path, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2)

print(f"Benchmark results successfully written to {out_path}")
PY

rm -f "$RAW_RESULTS_FILE"
