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
chunk file contains independently framed `(chunk, column)` segments. The
manifest records each segment's offset and length, so readers seek to and
decode only requested columns. Primitive values use packed arrays. String
columns are always dictionary encoded per chunk: unique UTF-8 values are stored
once and rows store `u32` dictionary codes.

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
including null components and dictionary codes. Composite-key inner and
left/right/full outer joins are available through SQL, including mixed-type
keys. Window ranking and running aggregates support multiple partition columns
and ascending or descending order.

Every chunk persists zone maps (textual min/max plus null count) in its
version-tolerant manifest metadata. Selective numeric predicates skip
impossible chunks and report scan/skip counts. Predicate columns are decoded
first; projection, aggregate, and grouping columns are decoded only for chunks
that survive zone-map and row selection. Results report actual segment bytes
read and decoded versus the full-decode baseline.
Large ungrouped `SUM(f64)` plans can use deterministic threaded reduction;
small inputs remain serial.

For the selective four-column demo query, the reader reports
`bytes_read=126`, `segments_decoded=2`, and `full_decode_bytes=423`; the
zone-map-eliminated chunk contributes no segment reads. These are file-level
metrics, not estimates from row gathering.

## SQL subset

```text
SELECT <column[, ...] | aggregate[, ...]>
FROM <table>
[WHERE <column> <op> <literal> [AND ...]]
[LEFT|RIGHT|FULL] JOIN <table> ON a.key = b.key [AND a.key2 = b.key2]
[GROUP BY <column>[, ...]]
[ORDER BY <column> [ASC|DESC]]
[LIMIT n]
```

Window expressions use a running frame from the start of each partition:

```text
ROW_NUMBER() OVER (PARTITION BY team ORDER BY amount)
SUM(amount) OVER (PARTITION BY team ORDER BY amount DESC)
```

`RANK` includes gaps after ties and `DENSE_RANK` does not. Null join keys
never match; unmatched outer-join projections are NULL. Ordinary comparisons
return no rows for NULL, while aggregates ignore NULL values (`COUNT(*)`
still counts rows). `IS NULL` and `IS NOT NULL` are supported.

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
  outer join:          median_ns=474476
  window:              median_ns=201171
  parallel sum serial: median_ns=200068
  parallel sum:        median_ns=464366
  zone-map chunks skipped=1
```

These runs measured 1.80x and 4.32x columnar latency advantages for filter+sum
and group-by respectively, with 9.8x fewer bytes scanned. The SIMD nullable
sum was 1.20x faster in this run, while the join probe is a simple baseline
probe rather than a claim about all join workloads. Results vary with CPU,
Zig version, and process load.

The at-scale wide-table benchmark uses 1,000,000 rows, 16 mixed-type columns,
16 chunks, and three measured runs. It reads only `id` and `amount` for the
lazy query and compares that with decoding every column:

```text
wide benchmark rows=1000000 columns=16
  lazy decode: median_ns=42239156 bytes_read=16251024 segments_decoded=32 sum=374999750000.00
  full decode:  median_ns=399697134 bytes_read=137508560 segments_decoded=256 sum=374999750000.00
  parallel sum serial: median_ns=716392 sum=499999500000.00
  parallel sum 4t:     median_ns=973243 sum=499999500000.00
  SIMD scalar:         median_ns=1063824 sum=374999750000.00
  SIMD vector:         median_ns=228581 sum=374999750000.00
```

At this scale, lazy decoding read 8.46x fewer bytes and was 9.47x faster than
full-chunk decoding for the narrow query. Four-thread reduction was still
0.74x the serial speed, so the conservative threaded query threshold remains
appropriate. The vector SIMD path was 4.65x faster than the scalar filtered
sum in this run. These are local ReleaseFast measurements, not universal
hardware guarantees.

## CLI and demo

Commands are `create-table`, `load`, `query`, `describe`, `stats`, and
`benchmark`. Run the complete fresh-directory demonstration with:

```sh
./zcol/run.sh
```

It creates a two-chunk table, loads nullable CSV, prints filtered, null,
composite-grouped, and joined results, shows storage statistics, and runs both
the 100k microbenchmark and the 1M-row wide-table benchmark with assertions on
known answers.

## Limitations

- Joins are equi-joins; window frames are limited to running partition-start
  frames and there are no subqueries or distributed execution.
- Threaded query execution currently applies to ungrouped floating-point SUM
  plans. Grouped and filtered aggregate plans remain serial unless they match
  that specialized path.
- Lazy decoding is file-level for predicate, projection, grouping, and
  aggregate columns; window and join paths still materialize the source
  columns needed by their execution algorithms.
- No transactions or concurrent writer protocol.
- One `ORDER BY` key and numeric aggregates.
- The benchmark is an executable microbenchmark, not a full query optimizer or
  production performance certification.
