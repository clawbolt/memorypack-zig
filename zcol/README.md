# zcol: pure-Zig columnar analytics

`zcol` is the repository's OLAP showcase: a small, standalone analytical
engine whose durable table representation is columnar and whose scans operate
on typed slices a chunk at a time.

## Module map

```text
zcol/
├── storage/  MemoryPack manifest and typed column chunks
├── exec/     vectorized filtering, projection, aggregates, grouping
├── sql/      SQL-subset parser and schema binder
├── cli/      create-table, load, query, describe, stats
├── bench/    column-vector versus wide-row benchmark
└── run.sh    fresh-table demonstration and assertions
```

The build exposes the CLI as:

```sh
zig build zcol -- <command> ...
```

## Storage format

A table directory contains `manifest.bin` and `chunk-N.bin` files. The
MemoryPack manifest contains version, chunk size, schema (`name` plus
`i64`/`f64`/`bool`/`string` kind), and a chunk index with row counts. Each
chunk is a MemoryPack object containing one typed vector for every schema
column. Primitive values use packed arrays. Strings are direct UTF-8
String columns are always dictionary encoded per chunk: unique UTF-8 values are
stored once and rows store `u32` dictionary codes.

Every column chunk carries a packed validity bitmap. CSV empty fields and the
literal `NULL` are null. Ordinary comparisons never match null; `IS NULL` and
`IS NOT NULL` are explicit predicates. Aggregates skip null values, while
`COUNT(*)` counts rows and `COUNT(column)` counts valid values.

Appends write and sync the chunk first, then write and sync a temporary
manifest and atomically rename it over the live manifest. Reopening decodes
the manifest and discovers only completed chunks. The table mutex protects
mutable schema/chunk state. Directory fsync is not exposed portably by Zig
0.16, so the implementation documents the same filesystem durability boundary
as the other repository examples.

## Execution model

The executor reads one chunk at a time, allocates a boolean selection vector,
and evaluates each predicate over the relevant typed slice. Projection copies
only selected values. Aggregates maintain typed-independent numeric state for
`count`, `sum`, `min`, `max`, and `avg`; grouping uses composite hash keys,
including null components and dictionary codes. A single-key hash inner join,
one-key `ORDER BY`, and `LIMIT` are also available.

## SQL subset

```text
SELECT <column[, ...] | aggregate[, ...]>
FROM <table>
[WHERE <column> <op> <literal> [AND ...]]
[JOIN <table> ON a.key = b.key]
[GROUP BY <column>[, ...]]
[ORDER BY <column> [ASC|DESC]]
[LIMIT n]
```

Operators are `=`, `<`, `<=`, `>`, `>=`, and `!=` for numeric values; string
and boolean equality are supported. Aggregates are `COUNT(*)`, `SUM`, `MIN`,
`MAX`, and `AVG`. Identifiers are resolved against the opened table schema.

Examples:

```sh
zig build zcol -- create-table /tmp/sales \
  --schema id:i64,amount:f64,active:bool,team:string
zig build zcol -- load /tmp/sales sales.csv
zig build zcol -- query /tmp/sales \
  "SELECT team, SUM(amount), COUNT(*) FROM sales GROUP BY team"
```

## Benchmark methodology and measured output

The benchmark generates one identical logical dataset for both paths, uses
seven runs and reports the median, and retains allocations between runs. The
column path touches only amount/team vectors (9 bytes per row in this model);
the row baseline touches an 88-byte record containing a 64-byte payload.
Checksums are printed for both paths so the loop cannot be discarded.

Representative ReleaseFast output from this repository:

```text
benchmark rows=100000
  filter+sum columnar: median_ns=132053 rows_per_sec=757271701 bytes_scanned=900000 sum=9375000.00
  filter+sum row:      median_ns=238081 rows_per_sec=420025117 bytes_scanned=8800000 sum=9375000.00
  group-by   columnar: median_ns=56417 rows_per_sec=1772515376 bytes_scanned=900000 sum=49950000.00
  group-by   row:      median_ns=243975 rows_per_sec=409878061 bytes_scanned=8800000 sum=49950000.00
  null-sum scalar:     median_ns=43342 sum=42814715.00
  null-sum SIMD:       median_ns=36222 sum=42814715.00
  join probe:          median_ns=213057 checksum=100000
  null-sum scalar:     median_ns=193067 sum=42814715.00
  null-sum SIMD:       median_ns=171732 sum=42814715.00
```

These runs measured 1.80x and 4.32x columnar latency advantages for filter+sum
and group-by respectively, with 9.8x fewer bytes scanned. The SIMD nullable
sum was 1.20x faster in this run, while the join probe is a simple baseline
probe rather than a claim about all join workloads. Results vary with CPU,
Zig version, and process load.

## CLI and demo

Commands are `create-table`, `load`, `query`, `describe`, `stats`, and
`benchmark`. Run the complete fresh-directory demonstration with:

```sh
./zcol/run.sh
```

It creates a two-chunk table, loads nullable CSV, prints filtered, null,
composite-grouped, and joined results, shows storage statistics, and runs the
benchmark with assertions on known answers.

## Limitations

- Only inner, single-key joins; no subqueries, windows, or distributed
  execution.
- No transactions or concurrent writer protocol.
- One `ORDER BY` key and numeric aggregates.
- The benchmark is an executable microbenchmark, not a full query optimizer or
  production performance certification.
