# zdb: an embedded document database

`zdb` is a deliberately small but complete embedded document database written
in pure Zig. It uses MemoryPack for every persisted structure and demonstrates
the pieces that a real local database needs:

- Materialized snapshot files.
- A durable append-only write-ahead log.
- Recovery by replaying the WAL over the snapshot.
- Graceful handling of a truncated final WAL frame.
- Compaction/checkpointing.
- An in-memory secondary index by document status.
- Version-tolerant document records.
- A CRUD and query command-line interface.

## Run the lifecycle demo

```sh
export PATH="$HOME/.dotnet:$HOME/.bin:$HOME/.local/bin:$HOME/.asdf/shims:$PATH"
./examples/zdb/run.sh
```

The application is also available directly:

```sh
zig build zdb -- db put 1 Ada --status active --score 95 --tags admin,early
zig build zdb -- db get 1
zig build zdb -- db query --status active
zig build zdb -- db query --tag admin
zig build zdb -- db delete 1
zig build zdb -- db compact
zig build zdb -- db stats
```

The first argument is a store directory. It contains `snapshot.bin` and
`wal.bin`.

## Document schema

Documents are version-tolerant MemoryPack objects:

```text
Document
  id: int32
  name: Str
  status: enum { draft, active, archived }
  score: int64
  due: nullable int32 (application-defined day number)
  tags: Str[]
```

The declaration includes:

```zig
pub const memorypack_version_tolerant = true;
```

This allows fields to be added later while older snapshots and WAL records
remain readable. The example intentionally keeps the serialized domain to
objects, enums, strings, arrays, integers, and nullable values.

## Storage architecture

### Snapshot

`compact` materializes all current documents into a version-tolerant
`Snapshot { version: i64, documents: []Document }` object and writes it as one
MemoryPack payload to `snapshot.bin`. A temporary snapshot is written first and
renamed into place before the WAL is cleared.

### WAL

Each mutation is a tagged union:

```text
Mutation
  tag 0: Put { document: Document }
  tag 1: Delete { id: int32 }
```

The WAL is an append-only sequence of:

```text
4-byte little-endian unsigned payload length
MemoryPack mutation payload
```

Every mutation is framed and flushed/synced before it is applied to the
in-memory map. On startup, `zdb` loads the snapshot first and then replays
complete WAL frames. Replay uses `memorypack.decodeFromReader`, with a
two-byte chunked reader to exercise partial input.

If a crash leaves an incomplete final header or payload, recovery stops at that
frame, ignores it, and preserves all earlier complete mutations. The lifecycle
script appends such a deliberately incomplete frame and verifies that the
database still opens and reports the recovered state.

### Secondary index

The engine maintains an in-memory status index mapping each status enum to
document IDs. `query --status active` reads IDs from this index rather than
scanning every document. The index is updated for puts, status changes, deletes,
snapshot loading, and WAL replay. Tag queries are also available and perform a
straightforward scan because tags are multi-valued.

## Commands

```text
put <id> <name> [--status draft|active|archived]
                 [--score <i64>] [--due <i32>] [--tags a,b,c]
get <id>
delete <id>
query [--status <status>] [--tag <tag>]
list
compact
stats
```

Each command opens the directory, recovers snapshot plus WAL, performs its
operation, and exits. This makes persistence and recovery visible across
separate CLI processes.

## Example output

```text
=== Create documents through separate durable WAL appends ===
put #1
put #2
put #3

--- state recovered from snapshot + WAL ---
documents=3, snapshot_version=0, wal_frames=3
#1 [active] Ada score=95 due=20250 tags=admin,early
#2 [draft] Bob score=70 tags=beta
#3 [active] Cara score=88 tags=admin

=== Indexed queries ===
query status=active (secondary index)
#1 [active] Ada score=95 due=20250 tags=admin,early
#3 [active] Cara score=88 tags=admin
query tag=admin
#1 [active] Ada score=95 due=20250 tags=admin,early
#3 [active] Cara score=88 tags=admin

=== Delete and compact ===
deleted #2
compacted snapshot_version=1, wal_frames=0
documents=2, snapshot_version=1, wal_frames=0

=== Simulate a crash during the next WAL append ===
put #4
Appended an incomplete final WAL frame.
Warning: ignored truncated final WAL frame.
documents=3, snapshot_version=1, wal_frames=1

=== Compact recovered state and verify final snapshot ===
Warning: ignored truncated final WAL frame.
compacted snapshot_version=2, wal_frames=0
documents=3, snapshot_version=2, wal_frames=0
#1 [active] Ada score=95 due=20250 tags=admin,early
#3 [active] Cara score=88 tags=admin
#4 [active] Dan score=81 tags=new
```

Map iteration order is not part of the on-disk contract; the snapshot remains
valid regardless of document ordering.
