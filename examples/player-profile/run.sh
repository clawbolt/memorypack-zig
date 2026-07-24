#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DIR="$ROOT/examples/player-profile"
INPUT="$DIR/profile.bin"
UPDATED="$DIR/profile_updated.bin"
export PATH="$HOME/.dotnet:$HOME/.bin:$HOME/.local/bin:$HOME/.asdf/shims:$PATH"

rm -f "$INPUT" "$UPDATED"

echo "=== Step 1: Zig writes profile.bin ==="
(cd "$ROOT" && zig build example -- write "$INPUT")

echo
echo "=== Step 2: C# MemoryPack reads, mutates, and writes profile_updated.bin ==="
dotnet run --project "$DIR/csharp/PlayerProfile.csproj" -- mutate "$INPUT" "$UPDATED"

echo
echo "=== Step 3: Zig reads profile_updated.bin ==="
(cd "$ROOT" && zig build example -- read "$UPDATED")
