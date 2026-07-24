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
3,NULL,false,beta
4,40,true,beta
EOF
cat >"$DATA/lookup.csv" <<'EOF'
id,label
2,second
4,fourth
1,first
EOF

cd "$ROOT"
export PATH="$HOME/.dotnet:$HOME/.bin:$HOME/.local/bin:$HOME/.asdf/shims:$PATH"
zig build zcol -- create-table "$DATA/table" --chunk-rows 2
zig build zcol -- load "$DATA/table" "$CSV"
zig build zcol -- create-table "$DATA/lookup" --schema id:i64,label:string
zig build zcol -- load "$DATA/lookup" "$DATA/lookup.csv"
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
NULLS=$(zig build zcol -- query "$DATA/table" "SELECT amount, team FROM sales WHERE amount IS NULL" 2>&1)
printf '%s\n' "$NULLS"
printf '%s\n' "$NULLS" | grep -q 'NULL'
COMPOSITE=$(zig build zcol -- query "$DATA/table" "SELECT team, id, SUM(amount) FROM sales GROUP BY team, id" 2>&1)
printf '%s\n' "$COMPOSITE"
printf '%s\n' "$COMPOSITE" | grep -q 'alpha'
JOIN=$(zig build zcol -- query "$DATA/table" "SELECT a.team, b.label FROM sales JOIN $DATA/lookup ON a.id = b.id ORDER BY b.label DESC LIMIT 2" 2>&1)
printf '%s\n' "$JOIN"
printf '%s\n' "$JOIN" | grep -q 'fourth'
zig build zcol -- benchmark 100000
printf '%s\n' "zcol demo complete"
