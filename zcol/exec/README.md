# zcol/exec

Chunk-at-a-time vectorized execution. Predicates scan primitive slices,
projections copy selected rows, and count/sum/min/max/avg plus composite hash
grouping operate without per-cell virtual dispatch. Null validity, scalar and
`@Vector` numeric paths, composite and outer hash joins, ordering, limiting,
window ranking/running aggregates, deterministic threaded floating-point SUM,
projection gathering after selection, and zone-map skipping are covered by
executor tests. The executor builds a union of predicate, grouping,
aggregation, and projection columns and asks storage for only those segments;
predicate selection therefore precedes decoding of non-predicate output
columns. Window aggregates use a running frame from partition start. Query
results expose bytes read, decoded segment count, and the full-decode byte
baseline.
