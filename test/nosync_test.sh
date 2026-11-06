#!/usr/bin/env bash
# test/nosync_test.sh - Verification suite for libnosync.so
# Tests compilation, fsync bypass, stats file counting, fork safety, O_SYNC stripping, and NOSYNC_DISABLE.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

TEST_TMP="$(mktemp -d /tmp/overclock-test.XXXXXX)"
cleanup() {
  rm -rf "$TEST_TMP"
}
trap cleanup EXIT

echo "=== overclock: running libnosync verification suite ==="
echo "Test workspace: $TEST_TMP"

# Check strace usability
STRACE_USABLE=1
if ! strace -c true >/dev/null 2>&1; then
  echo "WARNING: strace is unavailable or blocked by ptrace restrictions; skipping strace assertions"
  STRACE_USABLE=0
fi

LIB_PATH="$TEST_TMP/libnosync.so"

# Test 1: Build libnosync with -Wall -Wextra -Werror
echo "--- Test 1: Compile libnosync with -Werror ---"
gcc -O2 -shared -fPIC -pthread -U_FORTIFY_SOURCE -D_GNU_SOURCE -Wall -Wextra -Werror -o "$LIB_PATH" "$ROOT_DIR/src/nosync.c" -ldl
if [[ ! -f "$LIB_PATH" ]]; then
  echo "FAIL: Failed to build $LIB_PATH"
  exit 1
fi
echo "PASS: Compiled $LIB_PATH cleanly"

# Test 2: Baseline SQLite workload without LD_PRELOAD
echo "--- Test 2: Baseline SQLite workload (fsync enabled) ---"
SQLITE_SCRIPT="$TEST_TMP/sqlite_workload.py"
cat <<'EOF' > "$SQLITE_SCRIPT"
import sqlite3, sys
db_path = sys.argv[1]
con = sqlite3.connect(db_path)
con.execute("PRAGMA synchronous = FULL;")
con.execute("CREATE TABLE test (id INT);")
for i in range(200):
    con.execute("INSERT INTO test VALUES (?);", (i,))
    con.commit()
con.close()
EOF

DB_BASELINE="$TEST_TMP/baseline.db"
if [[ "$STRACE_USABLE" -eq 1 ]]; then
  STRACE_BASE_LOG="$TEST_TMP/strace_baseline.log"
  strace -f -c -e trace=fsync,fdatasync -o "$STRACE_BASE_LOG" python3 "$SQLITE_SCRIPT" "$DB_BASELINE"
  if ! grep -E -q 'fsync|fdatasync' "$STRACE_BASE_LOG"; then
    echo "FAIL: Expected fsync/fdatasync in baseline strace log, got none:"
    cat "$STRACE_BASE_LOG"
    exit 1
  fi
  echo "PASS: Baseline issued real fsync/fdatasync calls"
else
  python3 "$SQLITE_SCRIPT" "$DB_BASELINE"
  echo "SKIP: strace assertion skipped (strace unavailable)"
fi

# Test 3 & 4: SQLite workload with LD_PRELOAD & Stats verification
echo "--- Test 3 & 4: SQLite workload with libnosync & stats file ---"
DB_PRELOAD="$TEST_TMP/preload.db"
STATS_FILE="$TEST_TMP/nosync-stats"
: > "$STATS_FILE"

if [[ "$STRACE_USABLE" -eq 1 ]]; then
  STRACE_PRELOAD_LOG="$TEST_TMP/strace_preload.log"
  LD_PRELOAD="$LIB_PATH" NOSYNC_STATS_FILE="$STATS_FILE" strace -f -c -e trace=fsync,fdatasync -o "$STRACE_PRELOAD_LOG" python3 "$SQLITE_SCRIPT" "$DB_PRELOAD"
  if grep -E -q '^[[:space:]]+[0-9]+.*(fsync|fdatasync)' "$STRACE_PRELOAD_LOG"; then
    echo "FAIL: Expected 0 fsync/fdatasync calls under libnosync, found:"
    cat "$STRACE_PRELOAD_LOG"
    exit 1
  fi
  echo "PASS: 0 fsync/fdatasync calls reached the kernel under libnosync"
else
  LD_PRELOAD="$LIB_PATH" NOSYNC_STATS_FILE="$STATS_FILE" python3 "$SQLITE_SCRIPT" "$DB_PRELOAD"
  echo "SKIP: strace assertion skipped (strace unavailable)"
fi

# Assert stats file sums to >= 200 skipped sync calls
if [[ ! -s "$STATS_FILE" ]]; then
  echo "FAIL: Expected stats file $STATS_FILE to be non-empty"
  exit 1
fi

TOTAL_SKIPPED=0
while read -r _pid skipped _osync || [[ -n "$_pid" ]]; do
  if [[ "$skipped" =~ ^[0-9]+$ ]]; then
    TOTAL_SKIPPED=$(( TOTAL_SKIPPED + skipped ))
  fi
done < "$STATS_FILE"

echo "Recorded skipped sync calls: $TOTAL_SKIPPED"
if [[ "$TOTAL_SKIPPED" -lt 200 ]]; then
  echo "FAIL: Expected total skipped sync calls >= 200, got $TOTAL_SKIPPED"
  exit 1
fi
echo "PASS: Stats file recorded >= 200 skipped sync calls ($TOTAL_SKIPPED)"

# Test 5: Fork safety
echo "--- Test 5: Fork safety verification ---"
FORK_SCRIPT="$TEST_TMP/fork_test.py"
cat <<'EOF' > "$FORK_SCRIPT"
import os, sys, time

dummy_file = sys.argv[1]
fd = os.open(dummy_file, os.O_RDWR | os.O_CREAT, 0o666)

# Parent does 10 fsyncs
for _ in range(10):
    os.fsync(fd)

pid = os.fork()
if pid == 0:
    # Child process: does 5 fsyncs
    for _ in range(5):
        os.fsync(fd)
    os.close(fd)
    sys.exit(0)
else:
    # Parent process waits for child
    os.waitpid(pid, 0)
    os.close(fd)
    sys.exit(0)
EOF

FORK_STATS="$TEST_TMP/fork_stats.log"
FORK_FILE="$TEST_TMP/fork_dummy.bin"
: > "$FORK_STATS"

LD_PRELOAD="$LIB_PATH" NOSYNC_STATS_FILE="$FORK_STATS" python3 "$FORK_SCRIPT" "$FORK_FILE"

# Stats file should have exactly 2 lines: one with 5 and one with 10 (not 15!)
COUNTS=()
while read -r _pid skipped _osync || [[ -n "$_pid" ]]; do
  if [[ "$skipped" =~ ^[0-9]+$ ]]; then
    COUNTS+=("$skipped")
  fi
done < "$FORK_STATS"

echo "Fork safety counts: ${COUNTS[*]}"
if [[ "${#COUNTS[@]}" -ne 2 ]]; then
  echo "FAIL: Expected exactly 2 processes in fork stats, got ${#COUNTS[@]}:"
  cat "$FORK_STATS"
  exit 1
fi

# Sort counts to check [5, 10]
mapfile -t SORTED_COUNTS < <(printf '%s\n' "${COUNTS[@]}" | sort -n)

if [[ "${SORTED_COUNTS[0]}" -ne 5 || "${SORTED_COUNTS[1]}" -ne 10 ]]; then
  echo "FAIL: Expected counts [5, 10] showing counters reset on fork, but got [${SORTED_COUNTS[0]}, ${SORTED_COUNTS[1]}]"
  cat "$FORK_STATS"
  exit 1
fi
echo "PASS: Fork safety verified (child started at 0 and recorded 5, parent recorded 10)"

# Test 6: O_SYNC flag stripping
echo "--- Test 6: O_SYNC stripping verification ---"
OSYNC_SCRIPT="$TEST_TMP/osync_test.py"
cat <<'EOF' > "$OSYNC_SCRIPT"
import os, sys
path = sys.argv[1]
# Open with O_SYNC
flags = os.O_WRONLY | os.O_CREAT | getattr(os, 'O_SYNC', 0o4010000)
fd = os.open(path, flags, 0o666)
os.write(fd, b"hello")
os.close(fd)
EOF

OSYNC_STATS="$TEST_TMP/osync_stats.log"
OSYNC_FILE="$TEST_TMP/osync_dummy.bin"
: > "$OSYNC_STATS"

if [[ "$STRACE_USABLE" -eq 1 ]]; then
  OSYNC_STRACE_LOG="$TEST_TMP/osync_strace.log"
  LD_PRELOAD="$LIB_PATH" NOSYNC_STATS_FILE="$OSYNC_STATS" strace -e trace=openat -o "$OSYNC_STRACE_LOG" python3 "$OSYNC_SCRIPT" "$OSYNC_FILE"
  # Check that openat for osync_dummy.bin does NOT contain O_SYNC
  if grep -E 'osync_dummy\.bin' "$OSYNC_STRACE_LOG" | grep -q 'O_SYNC'; then
    echo "FAIL: openat still contains O_SYNC flag:"
    cat "$OSYNC_STRACE_LOG"
    exit 1
  fi
  echo "PASS: O_SYNC flag was stripped before reaching openat syscall"
else
  LD_PRELOAD="$LIB_PATH" NOSYNC_STATS_FILE="$OSYNC_STATS" python3 "$OSYNC_SCRIPT" "$OSYNC_FILE"
  echo "SKIP: strace assertion skipped (strace unavailable)"
fi

# Verify stats file recorded stripped_osync
STRIPPED_COUNT=0
while read -r _pid _skipped osync || [[ -n "$_pid" ]]; do
  if [[ "$osync" =~ ^[0-9]+$ ]]; then
    STRIPPED_COUNT=$(( STRIPPED_COUNT + osync ))
  fi
done < "$OSYNC_STATS"

if [[ "$STRIPPED_COUNT" -lt 1 ]]; then
  echo "FAIL: Expected stripped_osync >= 1 in stats, got $STRIPPED_COUNT"
  cat "$OSYNC_STATS"
  exit 1
fi
echo "PASS: Stats file recorded stripped O_SYNC ($STRIPPED_COUNT)"

# Test 7: NOSYNC_DISABLE=1 passthrough
echo "--- Test 7: NOSYNC_DISABLE=1 passthrough verification ---"
PASSTHROUGH_STATS="$TEST_TMP/passthrough_stats.log"
: > "$PASSTHROUGH_STATS"

if [[ "$STRACE_USABLE" -eq 1 ]]; then
  PASSTHROUGH_STRACE="$TEST_TMP/passthrough_strace.log"
  DB_PASSTHROUGH="$TEST_TMP/passthrough.db"
  NOSYNC_DISABLE=1 LD_PRELOAD="$LIB_PATH" NOSYNC_STATS_FILE="$PASSTHROUGH_STATS" strace -f -c -e trace=fsync,fdatasync -o "$PASSTHROUGH_STRACE" python3 "$SQLITE_SCRIPT" "$DB_PASSTHROUGH"
  if ! grep -E -q 'fsync|fdatasync' "$PASSTHROUGH_STRACE"; then
    echo "FAIL: NOSYNC_DISABLE=1 failed to pass fsync/fdatasync through:"
    cat "$PASSTHROUGH_STRACE"
    exit 1
  fi
  echo "PASS: NOSYNC_DISABLE=1 resulted in real fsync calls"
else
  echo "SKIP: strace assertion skipped (strace unavailable)"
fi

# Check that passthrough did not write to stats file
if [[ -s "$PASSTHROUGH_STATS" ]]; then
  echo "FAIL: Expected empty stats file in passthrough mode, got:"
  cat "$PASSTHROUGH_STATS"
  exit 1
fi
echo "PASS: Passthrough mode did not record any bypass stats"

echo "=== All libnosync tests passed successfully! ==="
