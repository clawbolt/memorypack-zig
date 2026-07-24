#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
DATA_DIR="$(mktemp -d "${TMPDIR:-/tmp}/memorypack-iothub.XXXXXX")"
PORT="${1:-39561}"
PID=""
export PATH="$HOME/.dotnet:$HOME/.bin:$HOME/.local/bin:$HOME/.asdf/shims:$PATH"

cleanup() {
  if [[ -n "$PID" ]] && kill -0 "$PID" 2>/dev/null; then
    kill "$PID" 2>/dev/null || true
    wait "$PID" 2>/dev/null || true
  fi
  rm -rf "$DATA_DIR"
}
trap cleanup EXIT

iothub() {
  (cd "$ROOT" && zig build iothub -- "$@") 2>&1
}

start() {
  local log="$DATA_DIR/gateway.log"
  (cd "$ROOT" && zig build iothub -- serve "$DATA_DIR" --port "$PORT") >"$log" 2>&1 &
  PID=$!
  for _ in {1..100}; do
    if ss -ltn | awk '{print $4}' | grep -Eq "(^|:)${PORT}$"; then return; fi
    if ! kill -0 "$PID" 2>/dev/null; then cat "$log"; exit 1; fi
    sleep 0.05
  done
  cat "$log"
  exit 1
}

stop() {
  iothub shutdown --port "$PORT" --token admin-token >/dev/null
  wait "$PID"
  PID=""
}

echo "=== Start IoT telemetry gateway ==="
start

echo
echo "=== Authentication ==="
if iothub ping --port "$PORT" --token wrong-token >/dev/null; then
  echo "bad token unexpectedly accepted" >&2
  exit 1
fi
iothub ping --port "$PORT" --token operator-token

echo
echo "=== Rate limiting ==="
iothub rate-test --port "$PORT" --token viewer-token
echo "rate limit: rejected request after configured budget"
sleep 1.1

echo
echo "=== Device registry and alert rule ==="
iothub register-device --port "$PORT" --token admin-token --id sensor-1 --name "Boiler sensor"
iothub register-device --port "$PORT" --token admin-token --id sensor-2 --name "Room sensor"
iothub list-devices --port "$PORT" --token viewer-token --limit 10
iothub get-device --port "$PORT" --token viewer-token --id sensor-1
iothub decommission-device --port "$PORT" --token operator-token --id sensor-2
iothub get-device --port "$PORT" --token viewer-token --id sensor-2
iothub audit-verify --port "$PORT" --token viewer-token
iothub add-rule --port "$PORT" --token operator-token --id hot --device sensor-1 --metric temperature --threshold 20

echo
echo "=== Telemetry ingestion and event-driven alert processing ==="
iothub ingest --port "$PORT" --token operator-token --device sensor-1 --metric temperature --value 18 --timestamp 100
iothub ingest --port "$PORT" --token operator-token --device sensor-1 --metric temperature --value 25 --timestamp 101
iothub alerts --port "$PORT" --token viewer-token

echo
echo "=== Time-series query with range and pagination ==="
iothub query --port "$PORT" --token viewer-token --device sensor-1 --metric temperature --start 100 --end 101 --limit 10

echo
echo "=== Restart gateway and verify durable state ==="
stop
start
iothub query --port "$PORT" --token viewer-token --device sensor-1 --metric temperature --start 0 --end 9999999999 --limit 10
iothub audit-verify --port "$PORT" --token viewer-token

echo
echo "=== Metrics snapshot ==="
iothub stats --port "$PORT" --token viewer-token
stop
echo "--- gateway log ---"
cat "$DATA_DIR/gateway.log"
echo
echo "=== IoT Hub telemetry flow complete ==="
