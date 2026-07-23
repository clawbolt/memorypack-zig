#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PATH="$HOME/.dotnet:$HOME/.bin:$HOME/.local/bin:$HOME/.asdf/shims:$PATH"
cd "$ROOT"

dotnet run --project "$ROOT/interop/csharp/MemoryPackInterop.csproj" -- generate
cp "$ROOT"/interop/vectors/*.bin "$ROOT"/src/vectors/
zig build test
mkdir -p "$ROOT/interop/zig_vectors"
zig run src/interop.zig 2>&1 | while read -r name hex; do
  printf '%s' "$hex" | xxd -r -p > "$ROOT/interop/zig_vectors/$name"
done
dotnet run --project "$ROOT/interop/csharp/MemoryPackInterop.csproj" -- verify-zig
