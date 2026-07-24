# examples/zcol/storage

Durable MemoryPack-backed columnar tables. A manifest stores the schema and
chunk index; every `(chunk, column)` is an independently framed segment with
an offset and length in the manifest. Each segment contains one byte-stable
MemoryPack column payload, validity bitmap, and (for strings) dictionary plus
`u32` codes. Readers seek directly to requested segments, verify the CRC, and
decode no sibling columns. Chunks are written before the atomically replaced
manifest, so a completed append is discoverable after reopening.

Chunk metadata includes version-tolerant zone maps with min/max values and null
counts for predicate pushdown. Manifest format version 2 is required; tables
written by the earlier single-blob format are rejected with the typed
`LegacyChunkFormat` error and can be recreated with `load`/`create-table`.
