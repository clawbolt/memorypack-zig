#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
DATA=$(mktemp -d "${TMPDIR:-/tmp}/zcol-demo.XXXXXX")
CSV="$DATA/sample.csv"
trap 'rm -rf "$DATA"' EXIT

cat >"$CSV" <<'EOF'
id,amount,active,team
1,10,true,alpha
2,20,true,alpha
3,30,false,beta
4,40,true,beta
EOF

cd "$ROOT"
export PATH="$HOME/.dotnet:$HOME/.bin:$HOME/.local/bin:$HOME/.asdf/shims:$PATH"
zig build zcol -- create-table "$DATA/table" --chunk-rows 2
zig build zcol -- load "$DATA/table" "$CSV"
zig build zcol -- describe "$DATA/table"
zig build zcol -- stats "$DATA/table"
FILTER=$(zig build zcol -- query "$DATA/table" "SELECT amount, team FROM sales WHERE amount >= 20" 2>&1)
printf '%s\n' "$FILTER"
printf '%s\n' "$FILTER" | grep -q '20.00'
AGG=$(zig build zcol -- query "$DATA/table" "SELECT SUM(amount), COUNT(*) FROM sales WHERE active = true" 2>&1)
printf '%s\n' "$AGG"
printf '%s\n' "$AGG" | grep -q '70.00'
GROUP=$(zig build zcol -- query "$DATA/table" "SELECT team, SUM(amount), COUNT(*) FROM sales GROUP BY team" 2>&1)
printf '%s\n' "$GROUP"
printf '%s\n' "$GROUP" | grep -q 'alpha'
zig build zcol -- benchmark 100000
printf '%s\n' "zcol demo complete"
