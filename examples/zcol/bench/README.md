# examples/zcol/bench

Fairness-oriented benchmark using the same generated data and predicate for a
column-vector loop and a row-oriented loop. It reports median latency, rows per
second, bytes touched, and aggregate equality, plus null-aware sums, join
probes, and scalar versus `@Vector` numeric paths. The row baseline includes a
wide payload to model a typical fact record that analytical scans must skip.
The `large` benchmark builds a 1,000,000-row, 16-column MemoryPack table and
measures lazy segment reads versus full-chunk decoding, four-thread reduction,
and scalar versus vector filtering. It reports actual file bytes and decoded
segment counts.
