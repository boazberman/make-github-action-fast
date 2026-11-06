#!/usr/bin/env bash
set -euo pipefail

# bench/real-world.sh - Orchestrate interleaved A/B benchmark for real-world projects
# Usage: bench/real-world.sh <project> <reps> <out.json>

PROJECT="${1:-}"
REPS="${2:-3}"
OUT_JSON="${3:-results/rw-${PROJECT}.json}"

if [ -z "$PROJECT" ]; then
  echo "Usage: $0 <vue-core|ripgrep|fastapi|redis> [reps] [out.json]" >&2
  exit 1
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNNER_TEMP="${RUNNER_TEMP:-/tmp}"
LIBNOSYNC="$RUNNER_TEMP/libnosync.so"

echo "=== Building libnosync.so ==="
gcc -O2 -shared -fPIC -pthread -U_FORTIFY_SOURCE -D_GNU_SOURCE -Wall -o "$LIBNOSYNC" "$REPO_ROOT/src/nosync.c" -ldl

WORK_DIR="$RUNNER_TEMP/bench_rw"
mkdir -p "$WORK_DIR"
TARGET_DIR="$WORK_DIR/$PROJECT"

echo "=== Preparing repository for project: $PROJECT ==="
case "$PROJECT" in
  vue-core)
    if [ ! -d "$TARGET_DIR/.git" ]; then
      rm -rf "$TARGET_DIR"
      git clone --quiet --depth 1 --branch "v3.4.27" "https://github.com/vuejs/core.git" "$TARGET_DIR"
    fi
    export PNPM_HOME="$RUNNER_TEMP/pnpm"
    export PATH="$PNPM_HOME:$PATH"
    PNPM_STORE="$RUNNER_TEMP/.pnpm-store"
    corepack enable >/dev/null 2>&1 || true
    (
      cd "$TARGET_DIR"
      pnpm config set store-dir "$PNPM_STORE"
      pnpm fetch
    )
    ;;

  ripgrep)
    if [ ! -d "$TARGET_DIR/.git" ]; then
      rm -rf "$TARGET_DIR"
      git clone --quiet --depth 1 --branch "14.1.1" "https://github.com/BurntSushi/ripgrep.git" "$TARGET_DIR"
    fi
    (
      cd "$TARGET_DIR"
      cargo fetch --locked
    )
    ;;

  fastapi)
    if [ ! -d "$TARGET_DIR/.git" ]; then
      rm -rf "$TARGET_DIR"
      git clone --quiet --depth 1 --branch "0.115.4" "https://github.com/fastapi/fastapi.git" "$TARGET_DIR"
    fi
    UV_CACHE="$RUNNER_TEMP/uv-cache"
    python3 -m pip install -q uv >/dev/null 2>&1 || true
    rm -rf "$RUNNER_TEMP/fastapi-warmup-venv"
    python3 -m venv "$RUNNER_TEMP/fastapi-warmup-venv"
    (
      cd "$TARGET_DIR"
      "$RUNNER_TEMP/fastapi-warmup-venv/bin/python" -m uv pip install --cache-dir "$UV_CACHE" pytest -e ".[all]" >/dev/null 2>&1 || true
    )
    rm -rf "$RUNNER_TEMP/fastapi-warmup-venv"
    ;;

  redis)
    if [ ! -d "$TARGET_DIR/.git" ]; then
      rm -rf "$TARGET_DIR"
      git clone --quiet --depth 1 --branch "7.2.5" "https://github.com/redis/redis.git" "$TARGET_DIR"
    fi
    if ! command -v tclsh >/dev/null 2>&1; then
      if [ "$EUID" -eq 0 ]; then
        apt-get update -qq && apt-get install -y -qq tcl
      elif sudo -n true 2>/dev/null; then
        sudo apt-get update -qq && sudo apt-get install -y -qq tcl
      fi
    fi
    ;;

  *)
    echo "Unknown project: $PROJECT" >&2
    exit 1
    ;;
esac

CONFIGS=("baseline" "all")
NUM_CONFIGS=${#CONFIGS[@]}

RAW_RESULTS_FILE="$RUNNER_TEMP/rw_raw_${PROJECT}_$$.txt"
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

echo "=== Running interleaved real-world benchmark: $PROJECT ($REPS reps x $NUM_CONFIGS configs) ==="

for ((r=0; r<REPS; r++)); do
  for ((i=0; i<NUM_CONFIGS; i++)); do
    cfg_idx=$(( (i + r) % NUM_CONFIGS ))
    cfg="${CONFIGS[$cfg_idx]}"

    # 1. Apply knobs
    apply_knobs "$cfg"

    # 2. Reset build state untimed
    (
      cd "$TARGET_DIR"
      git clean -xfdq
    )
    if [ "$PROJECT" = "fastapi" ]; then
      rm -rf "$RUNNER_TEMP/fastapi-bench-venv"
      python3 -m venv "$RUNNER_TEMP/fastapi-bench-venv"
    fi

    # 3. Drop page caches (untimed)
    drop_caches

    # 4. Setup stats file
    iter_stats="$RUNNER_TEMP/nosync_stats_rw_${PROJECT}_${cfg}_${r}_${i}.log"
    rm -f "$iter_stats"
    touch "$iter_stats"
    chmod 0666 "$iter_stats" 2>/dev/null || true

    # 5. Timed execution
    start=$(date +%s%N)
    if [ "$cfg" = "all" ]; then
      export LD_PRELOAD="$LIBNOSYNC"
      export NOSYNC_STATS_FILE="$iter_stats"
    else
      unset LD_PRELOAD
      unset NOSYNC_STATS_FILE
    fi

    case "$PROJECT" in
      vue-core)
        (
          cd "$TARGET_DIR"
          export PNPM_HOME="$RUNNER_TEMP/pnpm"
          export PATH="$PNPM_HOME:$PATH"
          pnpm install --frozen-lockfile --prefer-offline >/dev/null 2>&1
          pnpm build >/dev/null 2>&1
          pnpm test-unit --run >/dev/null 2>&1
        )
        ;;
      ripgrep)
        (
          cd "$TARGET_DIR"
          cargo build --release --locked >/dev/null 2>&1
          cargo test --workspace --locked >/dev/null 2>&1
        )
        ;;
      fastapi)
        (
          cd "$TARGET_DIR"
          UV_CACHE="$RUNNER_TEMP/uv-cache"
          "$RUNNER_TEMP/fastapi-bench-venv/bin/python" -m uv pip install --offline --cache-dir "$UV_CACHE" -e ".[all]" >/dev/null 2>&1
          "$RUNNER_TEMP/fastapi-bench-venv/bin/pytest" tests/test_tutorial -q >/dev/null 2>&1
        )
        ;;
      redis)
        (
          cd "$TARGET_DIR"
          make -j"$(nproc)" >/dev/null 2>&1
        )
        ;;
    esac

    end=$(date +%s%N)
    elapsed_ms=$(( (end - start) / 1000000 ))

    # 6. Extract skipped fsyncs
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

echo "=== Generating real-world results JSON ==="
python3 - "$PROJECT" "$REPS" "$OUT_JSON" "$RAW_RESULTS_FILE" <<'PY'
import json
import os
import sys

project = sys.argv[1]
reps = int(sys.argv[2])
out_path = sys.argv[3]
raw_file = sys.argv[4]

runner = os.environ.get("BENCH_RUNNER") or os.environ.get("RUNNER_NAME") or "local"
arch = os.uname().machine

results = {"baseline": [], "all": []}
skipped_fsyncs = {"baseline": 0, "all": 0}

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
    "workload": project,
    "runner": runner,
    "arch": arch,
    "reps": reps,
    "results": results,
    "skipped_fsyncs": skipped_fsyncs,
}

os.makedirs(os.path.dirname(os.path.abspath(out_path)), exist_ok=True)
with open(out_path, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2)

print(f"Real-world benchmark results successfully written to {out_path}")
PY

rm -f "$RAW_RESULTS_FILE"
