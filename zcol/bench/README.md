# zcol/bench

Fairness-oriented benchmark using the same generated data and predicate for a
column-vector loop and a row-oriented loop. It reports median latency, rows per
second, bytes touched, and aggregate equality, plus null-aware sums, join
probes, and scalar versus `@Vector` numeric paths. The row baseline includes a
wide payload to model a typical fact record that analytical scans must skip.
