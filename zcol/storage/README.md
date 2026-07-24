# zcol/storage

Durable MemoryPack-backed columnar tables. A manifest stores the schema and
chunk index; each chunk stores one typed vector per schema column. Chunks are
written before the atomically replaced manifest, so a completed append is
discoverable after reopening. Each column has a packed validity bitmap.
Strings use per-chunk dictionaries and `u32` code arrays, then decode
transparently for callers. Chunk metadata includes version-tolerant zone maps
with min/max values and null counts for predicate pushdown.
