# mq: durable MemoryPack message broker

`mq` is a pure-Zig, single-node durable message broker in the shape of a
small Kafka-like log service. It is separate from the `zdb` document database:
topics are append-only message logs, and consumer groups persist their next
offset independently.

The example is intentionally honest about its scope. It provides one broker,
one log per topic, at-least-once delivery, integrity checking, and a real TCP
protocol. It does not provide replication, partitions across nodes,
transactions, authentication, encryption, or exactly-once processing.

## Run the complete demo

```sh
export PATH="$HOME/.dotnet:$HOME/.bin:$HOME/.local/bin:$HOME/.asdf/shims:$PATH"
./examples/mq/run.sh
```

The optional first argument selects the TCP port:

```sh
./examples/mq/run.sh 39332
```

The script creates a temporary broker directory, starts and restarts the
broker, exercises committed and uncommitted consumers, corrupts a log tail,
prints stats, and cleans up.

## Architecture

Each topic is represented by one append-only file:

```text
<data-dir>/
  topics.bin
  offsets.bin
  topics/
    orders.log
```

`topics.bin` is an atomic MemoryPack snapshot of topic names. `offsets.bin` is
an atomic MemoryPack snapshot of `(group, topic, next_offset)` entries.
Messages are never rewritten during normal operation.

### Message schema

```text
Message
  offset: int64
  timestamp: int64
  key: Str
  value: Str
  headers: Str[]
```

The broker assigns `offset` and `timestamp`; producers supply the remaining
fields. The schema is version-tolerant and uses only stable MemoryPack
objects, integers, strings, and arrays.

### Topic log framing

Every topic record is:

```text
uint32 payload length (little-endian)
uint32 CRC32(payload) (little-endian)
MemoryPack Message payload
```

The broker flushes every frame and calls file sync before returning a
successful produce result by default. Recovery decodes records with
`decodeFromReader`, verifies CRC32, and requires monotonic offsets. A short
header, short payload, invalid checksum, invalid MemoryPack payload, or
unexpected offset ends the valid log. All complete records before that point
remain available.

The current implementation uses one log file per topic. Segment rotation and
retention policies are intentionally simplified and are not claimed.

### Consumer groups and delivery semantics

`fetch(topic, group, max)` starts at the group's committed next offset. A
consumer processes the returned batch and then sends `commit` with the next
offset. Commits are atomically persisted in `offsets.bin`.

This is **at-least-once** delivery:

1. Fetch returns messages.
2. The consumer processes them.
3. The consumer commits the next offset.

If the process crashes between steps 2 and 3, the same messages are returned
again after restart. The demo intentionally exercises this with `group-b`.
Applications must make handlers idempotent if duplicate processing is unsafe.
Ordering is guaranteed only by offset within one topic log.

## Configuration

The engine exposes:

```zig
const options = mq.Options{
    .data_dir = "broker-data",
    .durability = .fsync_every_write, // or .buffered
    .max_frame_size = 16 * 1024 * 1024,
    .max_batch_size = 1024,
};

var broker = try mq.Broker.open(io, allocator, options);
defer broker.deinit();
```

The mutex protects produce, fetch, commit, topic creation, and stats. The
testing suite exercises concurrent produces. `deinit` is idempotent.

## TCP protocol

The service runs as:

```sh
zig build mq -- serve broker-data --port 39331
```

Each TCP message is framed as:

```text
uint32 payload length (little-endian)
MemoryPack Request or Response payload
```

The frame is capped at 1 MiB and both sides loop until the complete frame has
been received. Multiple sequential client connections and requests are
supported.

Requests are a MemoryPack tagged union:

```text
Produce { topic, key, value, headers }
Fetch { topic, group, max }
Commit { topic, group, offset }
CreateTopic { topic }
ListTopics
Ping
Stats
Shutdown
```

Responses contain status, message, produced offset, fetched messages, topic
names, and aggregate stats. The protocol is suitable for another MemoryPack
client, but has no authentication or encryption and should not be exposed
directly to an untrusted network.

## CLI examples

```sh
# Server owns the durable data directory.
zig build mq -- serve broker-data --port 39331

# Client commands.
zig build mq -- create --port 39331 orders
zig build mq -- produce --port 39331 --topic orders --key order-1 --value shipped
zig build mq -- consume --port 39331 --topic orders --group payments --max 10 --commit
zig build mq -- consume --port 39331 --topic orders --group audit --max 10
zig build mq -- stats --port 39331
zig build mq -- shutdown --port 39331
```

`consume` without `--commit` deliberately demonstrates a crash window:
restarting the broker and consuming with the same group returns the same
uncommitted messages.

## Recovery and limitations

- Topic logs recover valid records and ignore only the invalid tail.
- Offset snapshots use temp-file write, file sync, and atomic rename.
- Topic metadata uses the same atomic snapshot pattern.
- Default produce and commit operations sync their files before acknowledging.
- The Zig 0.16 `std.Io.Dir` API does not expose a portable directory fsync;
  directory-entry durability after rename depends on the filesystem.
- There is one broker and one process-local mutex, not a distributed
  consensus or replication protocol.
- There is no multi-topic transaction, exactly-once guarantee, retention
  deletion, segment rotation, authentication, or TLS.

## Test coverage

`zig build test` runs testing-allocator tests for:

- Durable topic append and restart recovery.
- Consumer commits surviving broker restart.
- At-least-once redelivery without a commit.
- CRC/truncated-tail tolerance.
- Fetch batching and offset correctness.
- The shared broker state under concurrent operations.

## Captured demo output

```text
=== Start durable broker and create topic ===
create: topic created

=== Durable producer appends ===
produce: produced
produce: produced
produce: produced

=== Consumer group A fetches and commits ===
consume group=group-a count=2
  offset=0 key=order-1 value=shipped
  offset=1 key=order-2 value=packed
  committed offset=2
consume group=group-a count=1
  offset=2 key=order-3 value=queued
  committed offset=3
shutdown: bye

=== Restart broker: group A resumes after committed offset ===
consume group=group-a count=0

=== At-least-once: group B receives, crashes before commit ===
consume group=group-b count=2
  offset=0 key=order-1 value=shipped
  offset=1 key=order-2 value=packed
shutdown: bye
--- group B receives the same messages after restart ---
consume group=group-b count=2
  offset=0 key=order-1 value=shipped
  offset=1 key=order-2 value=packed
  committed offset=2

=== Corrupt/truncate tail and recover prior messages ===
shutdown: bye
stats: stats
  topics=1 messages=3 groups=2
shutdown: bye
--- final broker log ---
mq server listening on 127.0.0.1:39335
mq request kind=stats
mq request kind=shutdown

=== Broker lifecycle complete ===
```
