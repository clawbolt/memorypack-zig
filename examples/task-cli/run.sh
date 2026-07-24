#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DIR="$ROOT/examples/task-cli"
STORE="$(mktemp "${TMPDIR:-/tmp}/memorypack-tasks.XXXXXX.bin")"
LEGACY="$(mktemp "${TMPDIR:-/tmp}/memorypack-tasks-legacy.XXXXXX.bin")"
export PATH="$HOME/.dotnet:$HOME/.bin:$HOME/.local/bin:$HOME/.asdf/shims:$PATH"
trap 'rm -f "$STORE" "$LEGACY"' EXIT

rm -f "$STORE" "$LEGACY"
run_cli() {
  (cd "$ROOT" && zig build task-cli -- --store "$STORE" "$@")
}

echo "=== Version tolerance: legacy store loads in the current schema ==="
(cd "$ROOT" && zig build task-cli -- --store "$LEGACY" legacy-write)
(cd "$ROOT" && zig build task-cli -- --store "$LEGACY" list)

echo
echo "=== Fresh task session ==="
run_cli list
run_cli add "Write release notes" --priority high --due 20000
run_cli add "Review pull request" --priority normal
run_cli add "Plan team lunch" --priority low --due 20005

echo
echo "--- after adding three tasks ---"
run_cli list

echo
run_cli done 2
run_cli rm 1

echo
echo "--- after completing #2 and removing #1 ---"
run_cli list
