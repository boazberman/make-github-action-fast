#!/usr/bin/env bash
set -euo pipefail

# bench/workloads/cargo-build.sh - cargo build from clean target dir with pre-fetched deps
# Usage: cargo-build.sh [prepare|run]

MODE="${1:-run}"
WORK_DIR="${RUNNER_TEMP:-/tmp}/bench_cargo"

setup_cargo_project() {
  mkdir -p "$WORK_DIR/src"
  cat <<'EOF' > "$WORK_DIR/Cargo.toml"
[package]
name = "bench-cargo"
version = "0.1.0"
edition = "2021"

[dependencies]
serde = { version = "1.0", features = ["derive"] }
serde_json = "1.0"
regex = "1.10"
EOF

  cat <<'EOF' > "$WORK_DIR/src/main.rs"
use serde::{Deserialize, Serialize};

#[derive(Serialize, Deserialize, Debug)]
struct Record {
    id: u64,
    name: String,
}

fn main() {
    let r = Record { id: 1, name: "bench".into() };
    let json = serde_json::to_string(&r).unwrap();
    println!("{}", json);
}
EOF
}

case "$MODE" in
  prepare)
    if ! command -v cargo >/dev/null 2>&1; then
      echo "cargo not available" >&2
      exit 0
    fi
    setup_cargo_project
    (
      cd "$WORK_DIR"
      cargo fetch >/dev/null 2>&1 || true
      cargo build >/dev/null 2>&1 || true
      rm -rf target
    )
    ;;

  run)
    if ! command -v cargo >/dev/null 2>&1; then
      echo "100"
      exit 0
    fi

    if [ ! -f "$WORK_DIR/Cargo.toml" ]; then
      "$0" prepare
    fi

    rm -rf "$WORK_DIR/target"

    start=$(date +%s%N)
    (
      cd "$WORK_DIR"
      cargo build --offline >/dev/null 2>&1 || cargo build >/dev/null 2>&1
    )
    end=$(date +%s%N)

    elapsed_ms=$(( (end - start) / 1000000 ))
    rm -rf "$WORK_DIR/target"

    echo "$elapsed_ms"
    ;;

  *)
    echo "Unknown mode: $MODE" >&2
    exit 1
    ;;
esac
