#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
STORE="$(mktemp -d "${TMPDIR:-/tmp}/memorypack-zdb.XXXXXX")"
PORT="${1:-39231}"
export PATH="$HOME/.dotnet:$HOME/.bin:$HOME/.local/bin:$HOME/.asdf/shims:$PATH"
server_pid=""
cleanup() {
  if [[ -n "$server_pid" ]] && kill -0 "$server_pid" 2>/dev/null; then
    kill "$server_pid" 2>/dev/null || true
    wait "$server_pid" 2>/dev/null || true
  fi
  rm -rf "$STORE"
}
trap cleanup EXIT

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
echo "=== Network server/client round-trip ==="
SERVER_LOG="$STORE/server.log"
(cd "$ROOT" && zig build zdb -- "$STORE" serve --port "$PORT") >"$SERVER_LOG" 2>&1 &
server_pid=$!
for _ in {1..100}; do
  if ss -ltn | awk '{print $4}' | grep -Eq "(^|:)${PORT}$"; then break; fi
  if ! kill -0 "$server_pid" 2>/dev/null; then cat "$SERVER_LOG"; exit 1; fi
  sleep 0.05
done
if ! ss -ltn | awk '{print $4}' | grep -Eq "(^|:)${PORT}$"; then
  cat "$SERVER_LOG"
  echo "zdb server did not become ready" >&2
  exit 1
fi
(cd "$ROOT" && zig build zdb -- "$STORE" client --port "$PORT")
wait "$server_pid"
server_pid=""

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
