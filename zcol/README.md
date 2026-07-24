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
`memorypack.Str` vectors in v1; dictionary encoding is intentionally deferred
until cardinality statistics justify the additional format complexity.

Version 1 has **no null values**. This keeps typed loops tight and makes the
absence of validity checks explicit rather than silently treating a sentinel
as null.

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
`count`, `sum`, `min`, `max`, and `avg`; grouping uses a hash map keyed by the
group value. There is no per-row interface dispatch in the scan loops.

## SQL subset

```text
SELECT <column[, ...] | aggregate[, ...]>
FROM <table>
[WHERE <column> <op> <literal> [AND ...]]
[GROUP BY <column>]
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
  columnar: median_ns=160355 rows_per_sec=623616351 bytes_scanned=900000 sum=9375000.00
  row:      median_ns=669623 rows_per_sec=149337761 bytes_scanned=8800000 sum=9375000.00
```

This run measured a 4.18x columnar latency advantage and 9.8x fewer bytes
scanned. Results vary with CPU, Zig version, and process load; the benchmark
does not claim that columnar wins point lookups or every workload.

## CLI and demo

Commands are `create-table`, `load`, `query`, `describe`, `stats`, and
`benchmark`. Run the complete fresh-directory demonstration with:

```sh
./zcol/run.sh
```

It creates a two-chunk table, loads CSV, prints filtered and grouped results,
shows storage statistics, and runs the benchmark with assertions on known
answers.

## Limitations

- Single local table per query; no joins, subqueries, windows, or distributed
  execution.
- No transactions or concurrent writer protocol.
- No null values in v1.
- Strings use direct values rather than dictionary encoding.
- Aggregates are numeric and group-by supports one column.
- The benchmark is an executable microbenchmark, not a full query optimizer or
  production performance certification.
