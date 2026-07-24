#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DATA_DIR="$(mktemp -d "${TMPDIR:-/tmp}/memorypack-mq.XXXXXX")"
PORT="${1:-39331}"
export PATH="$HOME/.dotnet:$HOME/.bin:$HOME/.local/bin:$HOME/.asdf/shims:$PATH"
server_pid=""

cleanup() {
  if [[ -n "$server_pid" ]] && kill -0 "$server_pid" 2>/dev/null; then
    kill "$server_pid" 2>/dev/null || true
    wait "$server_pid" 2>/dev/null || true
  fi
  rm -rf "$DATA_DIR"
}
trap cleanup EXIT

mq() {
  (cd "$ROOT" && zig build mq -- "$@")
}

start_server() {
  local log="$DATA_DIR/server.log"
  (cd "$ROOT" && zig build mq -- serve "$DATA_DIR" --port "$PORT") >"$log" 2>&1 &
  server_pid=$!
  for _ in {1..100}; do
    if ss -ltn | awk '{print $4}' | grep -Eq "(^|:)${PORT}$"; then return; fi
    if ! kill -0 "$server_pid" 2>/dev/null; then cat "$log"; exit 1; fi
    sleep 0.05
  done
  cat "$log"
  echo "mq server did not become ready" >&2
  exit 1
}

stop_server() {
  mq shutdown --port "$PORT"
  wait "$server_pid"
  server_pid=""
}

echo "=== Start durable broker and create topic ==="
start_server
mq create --port "$PORT" orders

echo
echo "=== Durable producer appends ==="
mq produce --port "$PORT" orders order-1 shipped
mq produce --port "$PORT" orders order-2 packed
mq produce --port "$PORT" orders order-3 queued

echo
echo "=== Consumer group A fetches and commits ==="
mq consume --port "$PORT" orders group-a 2 --commit
mq consume --port "$PORT" orders group-a 10 --commit
stop_server

echo
echo "=== Restart broker: group A resumes after committed offset ==="
start_server
mq consume --port "$PORT" orders group-a 10

echo
echo "=== At-least-once: group B receives, crashes before commit ==="
mq consume --port "$PORT" orders group-b 2
stop_server
start_server
echo "--- group B receives the same messages after restart ---"
mq consume --port "$PORT" orders group-b 2 --commit

echo
echo "=== Corrupt/truncate tail and recover prior messages ==="
stop_server
printf '\x20\x00\x00\x00\x00\x00\x00\x00\x01' >> "$DATA_DIR/topics/orders.log"
start_server
mq stats --port "$PORT"
stop_server
echo "--- final broker log ---"
cat "$DATA_DIR/server.log"

echo
echo "=== Broker lifecycle complete ==="
