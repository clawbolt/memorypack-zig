# zcol/exec

Chunk-at-a-time vectorized execution. Predicates scan primitive slices,
projections copy selected rows, and count/sum/min/max/avg plus composite hash
grouping operate without per-cell virtual dispatch. Null validity, scalar and
`@Vector` numeric paths, composite and outer hash joins, ordering, limiting,
window ranking/running aggregates, deterministic threaded numeric reduction,
and zone-map skipping are covered by executor tests. Window aggregates use a
running frame from partition start.
