#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
STORE="$(mktemp -d "${TMPDIR:-/tmp}/memorypack-zdb.XXXXXX")"
export PATH="$HOME/.dotnet:$HOME/.bin:$HOME/.local/bin:$HOME/.asdf/shims:$PATH"
trap 'rm -rf "$STORE"' EXIT

run_zdb() {
  (cd "$ROOT" && zig build zdb -- "$STORE" "$@")
}

echo "=== Create documents through separate durable WAL appends ==="
run_zdb put 1 Ada --status active --score 95 --due 20250 --tags admin,early
run_zdb put 2 Bob --status draft --score 70 --tags beta
run_zdb put 3 Cara --status active --score 88 --tags admin

echo
echo "--- state recovered from snapshot + WAL ---"
run_zdb stats
run_zdb list

echo
echo "=== Indexed queries ==="
run_zdb query --status active
run_zdb query --tag admin

echo
echo "=== Delete and compact ==="
run_zdb delete 2
run_zdb compact
run_zdb stats

echo
echo "=== Simulate a crash during the next WAL append ==="
run_zdb put 4 Dan --status active --score 81 --tags new
printf '\xc8\x00\x00\x00\x01\x02' >> "$STORE/wal.bin"
echo "Appended an incomplete final WAL frame."
run_zdb stats

echo
echo "=== Compact recovered state and verify final snapshot ==="
run_zdb compact
run_zdb stats
run_zdb list
