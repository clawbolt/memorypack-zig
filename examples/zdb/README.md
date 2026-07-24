# zdb: embedded document storage with a service API

`zdb` is a pure-Zig embedded document store that demonstrates a production-
oriented persistence boundary around MemoryPack. It is intentionally
single-node and compact, but includes the durability and operational mechanics
that a local application needs:

- MemoryPack snapshots and mutation records.
- A write-ahead log with length framing and CRC32 integrity checks.
- WAL-before-apply ordering and configurable fsync policy.
- Crash recovery that stops at a bad or incomplete tail.
- Atomic snapshot replacement and ordered WAL clearing.
- A mutex-protected store API.
- Automatic compaction thresholds and paginated listing.
- A maintained status secondary index.
- A length-prefixed MemoryPack TCP service.

It is not a distributed database: there is no replication, MVCC, multi-key
transaction, authentication, or query planner. The mutex provides safe
concurrent access within one process; the WAL provides durable single-node
recovery.

## Quick start

```sh
export PATH="$HOME/.dotnet:$HOME/.bin:$HOME/.local/bin:$HOME/.asdf/shims:$PATH"
./examples/zdb/run.sh
```

The optional first argument selects the server port:

```sh
./examples/zdb/run.sh 39232
```

Direct CLI usage:

```sh
zig build zdb -- db put 1 Ada --status active --score 95 --tags admin,early
zig build zdb -- db get 1
zig build zdb -- db query --status active
zig build zdb -- db query --tag admin
zig build zdb -- db delete 1
zig build zdb -- db compact
zig build zdb -- db stats
```

The first argument is a store directory. It contains `snapshot.bin`,
`snapshot.tmp` while compaction is in progress, and `wal.bin`.

## Document schema

```text
Document
  id: int32
  name: Str
  status: enum { draft, active, archived }
  score: int64
  due: nullable int32 (application-defined day number)
  tags: Str[]
```

`Document` and `Snapshot` are version-tolerant MemoryPack objects. New fields
can be appended while older records remain readable under the repository's
version-tolerance rules. The persisted subset deliberately avoids unordered
maps and sets, whose enumeration order is not a byte-stable contract.

## Durability model

### WAL

Every `put` or `delete` is encoded as a MemoryPack tagged union and appended
before the in-memory map is changed:

```text
uint32 payload_length (little-endian)
uint32 crc32(payload) (little-endian)
MemoryPack mutation payload
```

The default `Options` value uses `fsync_every_write`. The frame is flushed and
the file is synced before the mutation is applied. `decodeFromReader` replays
each complete payload. A short header, short payload, invalid MemoryPack
payload, or CRC mismatch ends replay; records before that point remain
committed and the bad tail is ignored.

### Snapshots and compaction

Compaction materializes the current map into a version-tolerant snapshot,
encodes it, writes `snapshot.tmp`, and syncs that file. It then renames the
temporary file over `snapshot.bin`; only after the new snapshot is in place
does it truncate and sync the WAL. Thus a process crash before WAL clearing
leaves a new snapshot plus an old WAL, which is safe because replaying the
mutations is idempotent by primary key. A crash before rename leaves the old
snapshot and WAL.

The underlying Zig 0.16 `std.Io.Dir` API does not expose a portable directory
fsync operation, so the implementation syncs the snapshot and WAL files but
cannot promise directory-entry durability on every filesystem. This is the
remaining platform limitation; deployments needing strict rename persistence
should place the store on a filesystem with appropriate metadata guarantees.

### Configuration

The engine exposes:

```zig
const options = zdb.Options{
    .durability = .fsync_every_write, // or .buffered
    .auto_compact_wal_frames = 1000,   // zero disables automatic compaction
    .max_frame_size = 16 * 1024 * 1024,
};

var store = try zdb.Store.openWithOptions(io, allocator, "db", options);
defer store.close();
```

The public operations are `open`, `openWithOptions`, `close`/`deinit`,
`put`, `get`, `delete`, `queryStatus`, `listIds`, `compact`, and `count`.
Invalid limits return typed errors, and operations after close return
`error.StoreClosed`. `close` is idempotent.

## Queries and pagination

`query --status active` reads IDs from the maintained status index instead of
scanning all documents. `query --tag value` scans tags because a document can
have multiple tags. The engine's `listIds(allocator, offset, limit)` returns
stable ascending primary keys and rejects excessive limits. The CLI currently
prints all matching documents; callers embedding the engine can use
`listIds`/`queryStatus` to implement pagination.

## TCP service

Run a server:

```sh
zig build zdb -- db serve --port 39231
```

The included client drives the protocol:

```sh
zig build zdb -- db client --port 39231
```

Each TCP message is:

```text
uint32 payload length (little-endian)
MemoryPack request or response payload
```

The server loops over multiple requests on one connection, reads exact
lengths despite partial TCP reads, rejects frames larger than 1 MiB, and
cleanly handles EOF. The request object contains an operation enum plus
operation fields:

```text
ping, put, get, delete, query_status, compact, shutdown
```

Responses contain `ok`, request ID, result count, and a message. The protocol
uses only MemoryPack objects, enums, strings, arrays, integers, and nullable
values, making it suitable as a starting point for another MemoryPack client.
There is no authentication or encryption; bind and firewall it accordingly.

## Commands

```text
put <id> <name> [--status draft|active|archived]
                 [--score <i64>] [--due <i32>] [--tags a,b,c]
get <id>
delete <id>
query --status <status>
query --tag <tag>
list
compact
stats
serve --port <port>
client --port <port>
```

Each CLI invocation opens the directory, recovers snapshot plus WAL, performs
its operation, and closes the store.

## Verification coverage

The engine tests run under `zig build test` with the testing allocator and
cover WAL replay, snapshot-plus-WAL recovery, CRC corruption, truncated tails,
compaction and WAL clearing, pagination, status-index maintenance, and
concurrent puts through the mutex.

## Captured lifecycle and service output

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

=== Network server/client round-trip ===
rpc ping: ok=true message=pong count=0
rpc put: ok=true message=put count=1
rpc get: ok=true message=found count=1
rpc query_status: ok=true message=query count=3
rpc compact: ok=true message=compacted count=0
rpc shutdown: ok=true message=bye count=0
server round-trip assertions: passed

=== Indexed queries ===
query status=active (secondary index)
#7 [active] Networked score=77
#1 [active] Ada score=95 due=20250 tags=admin,early
#3 [active] Cara score=88 tags=admin
query tag=admin
#1 [active] Ada score=95 due=20250 tags=admin,early
#3 [active] Cara score=88 tags=admin

=== Simulate a crash during the next WAL append ===
put #4
Appended an incomplete final WAL frame.
Warning: ignored truncated final WAL frame.
documents=4, snapshot_version=2, wal_frames=1
```

The final compaction repeats the warning while inspecting the intentionally
truncated tail, then writes a clean snapshot and clears the WAL.
