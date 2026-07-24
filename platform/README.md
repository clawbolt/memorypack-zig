# MemoryPack IoT telemetry platform

`platform/` is the flagship pure-Zig system showcase in this repository. It
combines a device registry, durable telemetry ingestion, event-driven
threshold alerting, time-series queries, compliance auditing, and an
authenticated TCP gateway. Every persisted record and wire request is
MemoryPack encoded.

## Module map

```text
                 +----------------------+
 operator/client | platform/cli         |
                 +----------+-----------+
                            | MemoryPack TCP
                 +----------v-----------+
                 | platform/gateway     |
                 | auth + rate limiting |
                 +----------+-----------+
                            |
                 +----------v-----------+
                 | platform/services    |
                 | registry / ingest    |
                 | alerting / queries   |
                 +----+----------+------+
                      |          |
             +--------v--+   +---v---------+
             | storage   |   | broker      |
             | snapshot  |   | topic log   |
             | WAL/CRC   |   | offsets     |
             +-----------+   +-------------+
                      |
                 +----v-----+
                 | audit    |
                 | SHA chain|
                 +----------+

 core: config, logs, metrics, CRC framing, TCP framing
 e2e: real gateway lifecycle harness
```

## Data flow

1. An operator registers a device and adds an alert rule.
2. The gateway authenticates the request and routes it to services.
3. Ingestion persists a `Reading` under a namespaced time-series key and
   publishes a MemoryPack event to the telemetry topic.
4. The alerting consumer fetches events, evaluates rules, persists alerts, and
   commits its consumer offset.
5. Queries read the durable reading collection; audit verification checks the
   compliance chain.

## Run the demo

```sh
export PATH="$HOME/.dotnet:$HOME/.bin:$HOME/.local/bin:$HOME/.asdf/shims:$PATH"
./platform/e2e/run.sh
```

Or start the service manually:

```sh
zig build platform -- serve ./platform-data --port 39561
zig build platform -- register-device --port 39561 --token admin-token \
  --id sensor-1 --name "Boiler sensor"
zig build platform -- ingest --port 39561 --token operator-token \
  --device sensor-1 --metric temperature --value 25 --timestamp 101
zig build platform -- alerts --port 39561 --token viewer-token
```

## Persistence and guarantees

`core` provides the common `length + CRC32 + MemoryPack payload` framing.
Storage snapshots are MemoryPack objects and mutations are CRC-protected WAL
frames. The broker uses CRC-protected event frames and a durable MemoryPack
consumer-offset file. Audit entries use CRC framing plus a SHA-256 hash chain.
Recovery keeps complete records before a truncated or invalid tail.

The alert consumer is **at least once**: it commits only after processing.
If the process stops between processing and commit, the event is delivered
again. Alert persistence currently uses the broker offset as the alert ID, so
reprocessing the same event replaces the same logical alert rather than
creating an unbounded duplicate in the demo. This is not a distributed
exactly-once guarantee.

This is a single-node platform. It has no replication, partition leadership,
multi-node consensus, encryption, or cross-record transactions. Snapshot
rename durability has the same filesystem directory-fsync portability caveat
as the existing examples. Audit is tamper-evident, not tamper-proof: an
attacker who can rewrite the complete file can recompute the chain. External
tip anchoring or signing is required for stronger evidence.

## Domain records

```text
Device  { id, name, kind, status, tags, registered_at }
Reading { device_id, metric, value: f64, timestamp }
Rule    { id, device_id, metric, op(gt/lt/eq), threshold: f64 }
Alert   { id, rule_id, device_id, metric, value, timestamp }
```

Readings are stored as:

```text
<device-id>/<metric>/<timestamp> -> hex(MemoryPack(Reading))
```

Hex encoding keeps arbitrary MemoryPack bytes valid inside the storage
collection's UTF-8 `Str` value while preserving the original byte-stable
payload for decoding. The event broker carries the same hex payload.

## Gateway protocol

TCP requests and responses use:

```text
uint32 little-endian payload length
MemoryPack Request or Response
```

Requests include `Ping`, `RegisterDevice`, `Ingest`, `AddRule`, `Query`,
`Alerts`, `AuditVerify`, `Stats`, and `Shutdown`. Every request carries a
token. The default development tokens are:

```text
admin-token     admin
operator-token  operator
viewer-token    viewer
```

The gateway rejects unknown tokens and applies a simple per-token request
budget per second. The protocol supports partial reads, multiple requests per
connection, oversized-frame rejection, typed failure responses, and graceful
shutdown.

CLI commands:

```text
serve <dir> --port N
register-device
ingest
add-rule
query
alerts
audit-verify
stats
shutdown
```

## Operations and module APIs

- `core`: `Config`, `Metrics`, `writeFrame`, `readFrame`,
  `writeDiskFrame`, `readDiskFrames`.
- `storage.Store`: `open`, `deinit`, `put`, `get`, `delete`, `list`,
  `compact`, `stats`.
- `broker.Broker`: `open`, `publish`, `fetch`, `commit`, `stats`.
- `audit.Store`: `open`, `append`, `verify`, `deinit`.
- `services.Platform`: `registerDevice`, `addRule`, `ingest`,
  `processAlerts`, `queryReadings`, `alerts`.
- `gateway.Gateway`: `open`, `handle`, `deinit`.

All stores use mutexes for shared state and tests use the Zig testing
allocator.

## Captured e2e output

```text
=== Start IoT telemetry gateway ===

=== Authentication ===
ping: ok=true count=0 intact=true message=pong

=== Rate limiting ===
rate limit: rejected request after configured budget

=== Device registry and alert rule ===
register-device: ok=true count=1 intact=true message=device registered
add-rule: ok=true count=1 intact=true message=rule added

=== Telemetry ingestion and event-driven alert processing ===
ingest: ok=true count=1 intact=true message=reading ingested
alerts: ok=true count=1 intact=true message=alerts
  hot temperature 25

=== Time-series query with range and pagination ===
query: ok=true count=2 intact=true message=query complete
  sensor-1 temperature 18 100
  sensor-1 temperature 25 101

=== Restart gateway and verify durable state ===
query: ok=true count=2 intact=true message=query complete
audit-verify: ok=true count=0 intact=true message=audit intact

=== Metrics snapshot ===
stats: ok=true count=4 intact=true message=stats

=== IoT telemetry platform flow complete ===
```

The exact counters can vary with additional operator requests, but the
authentication rejection, rate-limit rejection, alert, restart recovery, and
audit verification are required assertions of the harness.
