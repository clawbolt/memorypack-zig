# zcol/exec

Chunk-at-a-time vectorized execution. Predicates scan primitive slices,
projections copy selected rows, and count/sum/min/max/avg plus one-column
hash grouping operate without per-cell virtual dispatch.
