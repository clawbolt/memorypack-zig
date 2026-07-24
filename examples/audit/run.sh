#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DATA_DIR="$(mktemp -d "${TMPDIR:-/tmp}/memorypack-audit.XXXXXX")"
PORT="${1:-39451}"
server_pid=""
export PATH="$HOME/.dotnet:$HOME/.bin:$HOME/.local/bin:$HOME/.asdf/shims:$PATH"

cleanup() {
  if [[ -n "$server_pid" ]] && kill -0 "$server_pid" 2>/dev/null; then
    kill "$server_pid" 2>/dev/null || true
    wait "$server_pid" 2>/dev/null || true
  fi
  rm -rf "$DATA_DIR"
}
trap cleanup EXIT

audit() {
  (cd "$ROOT" && zig build audit -- "$@")
}

start_server() {
  local log="$DATA_DIR/server.log"
  (cd "$ROOT" && zig build audit -- serve "$DATA_DIR" --port "$PORT") >"$log" 2>&1 &
  server_pid=$!
  for _ in {1..100}; do
    if ss -ltn | awk '{print $4}' | grep -Eq "(^|:)${PORT}$"; then return; fi
    if ! kill -0 "$server_pid" 2>/dev/null; then cat "$log"; exit 1; fi
    sleep 0.05
  done
  cat "$log"
  echo "audit server did not become ready" >&2
  exit 1
}

stop_server() {
  audit shutdown --port "$PORT"
  wait "$server_pid"
  server_pid=""
}

echo "=== Start compliance audit service ==="
start_server

echo
echo "=== Append login, permission, and data-access events ==="
audit log --port "$PORT" --actor alice --action login --resource portal --detail success
audit log --port "$PORT" --actor bob --action permission_change --resource reports --detail grant
audit log --port "$PORT" --actor alice --action data_access --resource reports --detail export

echo
echo "=== Query Alice's audit history ==="
audit query --port "$PORT" --actor alice

echo
echo "=== Verify intact chain ==="
audit verify --port "$PORT"
stop_server

echo
echo "=== Simulate an attacker modifying entry sequence 1 ==="
python3 - "$DATA_DIR/audit.log" <<'PY'
import struct
import sys
import zlib

path = sys.argv[1]
data = bytearray(open(path, "rb").read())
position = 0
for index in range(3):
    length = struct.unpack_from("<I", data, position)[0]
    payload = position + 8
    if index == 1:
        data[payload + length - 1] ^= 1
        crc = zlib.crc32(data[payload:payload + length]) & 0xffffffff
        struct.pack_into("<I", data, position + 4, crc)
        break
    position += 8 + length
open(path, "wb").write(data)
PY

echo
echo "=== Restart and detect tampering ==="
start_server
verification="$(audit verify --port "$PORT" 2>&1)"
printf '%s\n' "$verification"
grep -q "TAMPERING DETECTED at seq 1" <<<"$verification"

echo
echo "=== Compliance statistics ==="
audit stats --port "$PORT"
stop_server
echo "--- final server log ---"
cat "$DATA_DIR/server.log"

echo
echo "=== Tamper-evident audit flow complete ==="
