# zcol/exec

Chunk-at-a-time vectorized execution. Predicates scan primitive slices,
projections copy selected rows, and count/sum/min/max/avg plus composite hash
grouping operate without per-cell virtual dispatch. Null validity, scalar and
`@Vector` numeric paths, single-key hash joins, ordering, and limiting are
covered by the executor tests.
