#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DIR="$ROOT/examples/rpc-socket"
PORT="${1:-39123}"
LOG="$DIR/server.log"
export PATH="$HOME/.dotnet:$HOME/.bin:$HOME/.local/bin:$HOME/.asdf/shims:$PATH"

rm -f "$LOG"
server_pid=""
cleanup() {
  if [[ -n "$server_pid" ]] && kill -0 "$server_pid" 2>/dev/null; then
    kill "$server_pid" 2>/dev/null || true
    wait "$server_pid" 2>/dev/null || true
  fi
  rm -f "$LOG"
}
trap cleanup EXIT

echo "=== Starting real C# MemoryPack RPC server on port $PORT ==="
dotnet run --project "$DIR/csharp/RpcServer.csproj" -- "$PORT" >"$LOG" 2>&1 &
server_pid=$!

ready=0
for _ in {1..100}; do
  if [[ -f "$LOG" ]] && grep -q "RPC server listening" "$LOG"; then
    if ss -ltn | awk '{print $4}' | grep -Eq "(^|:)${PORT}$"; then
      ready=1
      break
    fi
  fi
  if ! kill -0 "$server_pid" 2>/dev/null; then
    cat "$LOG"
    exit 1
  fi
  sleep 0.05
done
if [[ "$ready" != 1 ]]; then
  cat "$LOG"
  echo "server did not become ready" >&2
  exit 1
fi

echo
echo "=== Zig client exchange ==="
(cd "$ROOT" && zig build rpc-client -- "$PORT")

echo
echo "=== C# server log ==="
cat "$LOG"
