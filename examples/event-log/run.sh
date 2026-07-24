#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LOG="$(mktemp "${TMPDIR:-/tmp}/memorypack-event-log.XXXXXX.bin")"
export PATH="$HOME/.dotnet:$HOME/.bin:$HOME/.local/bin:$HOME/.asdf/shims:$PATH"
trap 'rm -f "$LOG"' EXIT

run_log() {
  (cd "$ROOT" && zig build event-log -- "$LOG" "$@")
}

echo "=== Empty event-sourced account ==="
run_log replay

echo
echo "=== Append account opening and first transactions ==="
run_log open Ada
run_log deposit 100
run_log withdraw 30
echo "--- replay after first process runs ---"
run_log replay

echo
echo "=== Append another transaction in a later process ==="
run_log deposit 25
echo "--- replay after appending to the existing log ---"
run_log state
