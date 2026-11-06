#!/usr/bin/env bash
set -euo pipefail

# bench/workloads/npm-ci.sh - npm ci offline from a warmed cache
# Usage: npm-ci.sh [prepare|run]

MODE="${1:-run}"
WORK_DIR="${RUNNER_TEMP:-/tmp}/bench_npm"

setup_package_files() {
  mkdir -p "$WORK_DIR"
  cat <<'EOF' > "$WORK_DIR/package.json"
{
  "name": "bench-npm",
  "version": "1.0.0",
  "private": true,
  "dependencies": {
    "express": "^4.19.2",
    "lodash": "^4.17.21"
  },
  "devDependencies": {
    "eslint": "^8.57.0",
    "jest": "^29.7.0",
    "typescript": "^5.4.5",
    "webpack": "^5.91.0"
  }
}
EOF
}

case "$MODE" in
  prepare)
    setup_package_files
    (
      cd "$WORK_DIR"
      npm install --package-lock-only --ignore-scripts --no-audit --no-fund >/dev/null 2>&1
      npm ci --ignore-scripts --no-audit --no-fund >/dev/null 2>&1
      rm -rf node_modules
    )
    ;;

  run)
    if [ ! -f "$WORK_DIR/package-lock.json" ]; then
      "$0" prepare
    fi

    rm -rf "$WORK_DIR/node_modules"

    start=$(date +%s%N)
    (
      cd "$WORK_DIR"
      npm ci --ignore-scripts --no-audit --no-fund --prefer-offline >/dev/null 2>&1
    )
    end=$(date +%s%N)

    elapsed_ms=$(( (end - start) / 1000000 ))
    rm -rf "$WORK_DIR/node_modules"

    echo "$elapsed_ms"
    ;;

  *)
    echo "Unknown mode: $MODE" >&2
    exit 1
    ;;
esac
