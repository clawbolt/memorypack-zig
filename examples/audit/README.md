# audit: tamper-evident compliance log

`audit` is a pure-Zig compliance and security showcase. It records immutable
in-process audit entries in an append-only MemoryPack log and links every
entry to its predecessor with SHA-256. A verifier can therefore detect a
modified field, deleted entry, inserted entry, or reordered entry.

This is **tamper-evident**, not tamper-proof. An attacker who can rewrite the
entire file and replace every subsequent hash can recompute a valid chain.
Production deployments should externally witness or sign the tip hash (for
example in a WORM store, a transparency service, or a separate signing
system).

## Run the compliance flow

```sh
export PATH="$HOME/.dotnet:$HOME/.bin:$HOME/.local/bin:$HOME/.asdf/shims:$PATH"
./examples/audit/run.sh
```

The script uses a fresh directory, appends representative compliance events,
queries one actor, verifies the intact chain, modifies an on-disk payload while
updating its CRC, restarts the service, and proves that the hash verifier
detects the tampering.

## Hash-chain model

An entry is:

```text
Entry
  seq:        int64
  timestamp:  int64
  actor:      Str
  action:     Str
  resource:   Str
  detail:     Str
  prev_hash:  byte[32]
  entry_hash: byte[32]
```

The first entry uses 32 zero bytes as its `prev_hash`. The canonical hashed
core is the MemoryPack serialization of:

```text
Core
  seq
  timestamp
  actor
  action
  resource
  detail
```

The hash formula is:

```text
entry_hash = SHA256(prev_hash || MemoryPack(Core))
```

`entry_hash` itself is excluded from `Core`. Verification starts from the
genesis zero hash, requires sequence numbers `0, 1, 2, ...`, checks each
`prev_hash` against the previous entry, and recomputes every `entry_hash`.
It reports the first broken sequence and reason.

## On-disk format and durability

The store layout is:

```text
<data-dir>/
  audit.log
```

Every record is framed as:

```text
uint32 payload length (little-endian)
uint32 CRC32(payload) (little-endian)
MemoryPack Entry payload
```

The CRC detects accidental write corruption and incomplete tails. The
cryptographic chain detects intentional changes even when an attacker updates
the CRC. The broker flushes and syncs each frame before acknowledging an
append by default. Recovery reads complete frames, stops at the first
truncated/oversized/CRC-invalid payload, truncates that invalid tail, and
restores the last decoded sequence and tip hash.

The `buffered` durability option is available for throughput-oriented local
experiments. It does not provide the same acknowledgement durability as the
default `fsync_every_write`.

## Engine API

```zig
const options = audit.Options{
    .data_dir = "audit-data",
    .durability = .fsync_every_write,
    .max_frame_size = 16 * 1024 * 1024,
};

var store = try audit.Store.open(io, allocator, options);
defer store.deinit();

const seq = try store.append(.{
    .actor = .{ .bytes = "alice" },
    .action = .{ .bytes = "login" },
    .resource = .{ .bytes = "portal" },
    .detail = .{ .bytes = "success" },
});
const result = try store.verify();
```

The store mutex protects appends, queries, verification, and statistics.
`deinit` is idempotent. Query supports actor/action filters, sequence ranges,
and bounded offset/limit pagination.

## TCP service

Start the service:

```sh
zig build audit -- serve audit-data --port 39451
```

Each request and response uses:

```text
uint32 payload length (little-endian)
MemoryPack Request or Response
```

The server supports partial reads, multiple sequential requests, clean client
disconnects, and a 1 MiB frame limit. Requests are a tagged union:

```text
Append { actor, action, resource, detail }
Query { actor?, action?, start_seq?, end_seq?, offset, limit }
Verify
Stats
Ping
Shutdown
```

Responses carry status/message, sequence, queried entries, verification
status, broken sequence, entry count, next sequence, and the current tip hash.

Client examples:

```sh
zig build audit -- log --port 39451 \
  --actor alice --action login --resource portal --detail success
zig build audit -- query --port 39451 --actor alice
zig build audit -- verify --port 39451
zig build audit -- stats --port 39451
zig build audit -- shutdown --port 39451
```

## CRC versus cryptographic evidence

- **CRC32** is an accidental-corruption guard. It is not secret and is easy
  for an attacker to recompute.
- **SHA-256 chaining** makes edits, deletion, insertion, and reordering
  evident when the original chain tip or an earlier trusted checkpoint is
  retained.
- **External anchoring/signing** is needed for stronger evidence. Without an
  external witness, someone with unrestricted write access can rewrite the
  entire chain from the modified point onward.

The example does not implement signatures, key management, remote anchoring,
replication, WORM storage, authentication, authorization, encryption, or
multi-node consensus.

## Captured output

```text
=== Start compliance audit service ===

=== Append login, permission, and data-access events ===
log: seq=0
log: seq=1
log: seq=2

=== Query Alice's audit history ===
query: count=2
  seq=0 actor=alice action=login resource=portal detail=success
  seq=2 actor=alice action=data_access resource=reports detail=export

=== Verify intact chain ===
verify: chain intact, 3 entries

=== Simulate an attacker modifying entry sequence 1 ===

=== Restart and detect tampering ===
verify: TAMPERING DETECTED at seq 1: entry hash mismatch

=== Compliance statistics ===
stats: entries=3 next_seq=3
--- final server log ---
audit server listening on 127.0.0.1:39451
audit request kind=verify
audit request kind=stats
audit request kind=shutdown

=== Tamper-evident audit flow complete ===
```

## Tests

`zig build test` covers:

- Append/restart recovery and intact verification.
- Field tampering with a recomputed CRC.
- Middle-entry deletion.
- Entry reordering.
- Truncated/CRC-invalid tails.
- Concurrent appenders and sequence consistency.
