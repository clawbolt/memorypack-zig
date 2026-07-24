# zcol/storage

Durable MemoryPack-backed columnar tables. A manifest stores the schema and
chunk index; each chunk stores one typed vector per schema column. Chunks are
written before the atomically replaced manifest, so a completed append is
discoverable after reopening. Version 1 has no null values and uses direct
UTF-8 string vectors rather than dictionary encoding.
