#!/usr/bin/env bash
set -euo pipefail

# bench/workloads/sqlite.sh - SQLite 2,000 FULL synchronous commits
# Usage: sqlite.sh [prepare|run]

MODE="${1:-run}"
WORK_DIR="${RUNNER_TEMP:-/tmp}/bench_sqlite"
DB_FILE="$WORK_DIR/bench.db"

case "$MODE" in
  prepare)
    mkdir -p "$WORK_DIR"
    python3 -c "import sqlite3" >/dev/null 2>&1
    rm -f "${DB_FILE}"*
    ;;

  run)
    mkdir -p "$WORK_DIR"
    rm -f "${DB_FILE}"*

    python3 - "$DB_FILE" <<'PY'
import sqlite3
import sys
import time

db_path = sys.argv[1]
conn = sqlite3.connect(db_path)
conn.execute("PRAGMA journal_mode=DELETE;")
conn.execute("PRAGMA synchronous=FULL;")
conn.execute("CREATE TABLE bench (id INTEGER PRIMARY KEY, val TEXT);")
conn.commit()

num_commits = 2000
t0 = time.perf_counter()
for i in range(num_commits):
    conn.execute("INSERT INTO bench (val) VALUES (?);", (f"record-{i}",))
    conn.commit()

elapsed_ms = (time.perf_counter() - t0) * 1000.0
conn.close()

print(f"{elapsed_ms:.1f}")
PY

    rm -f "${DB_FILE}"*
    ;;

  *)
    echo "Unknown mode: $MODE" >&2
    exit 1
    ;;
esac
