# Pure-Zig append-only event log

This example is a small event-sourced bank ledger written entirely in Zig.
Commands append domain events to a log file. The current account state is never
stored as a snapshot: each `replay` invocation reads and applies every event
from the beginning of the log.

## Run

From the repository root:

```sh
export PATH="$HOME/.dotnet:$HOME/.bin:$HOME/.local/bin:$HOME/.asdf/shims:$PATH"
./examples/event-log/run.sh
```

The application is also available through the root build:

```sh
zig build event-log -- events.bin open Ada
zig build event-log -- events.bin deposit 100
zig build event-log -- events.bin withdraw 30
zig build event-log -- events.bin replay
```

The first argument is the log path. The log is created if it does not exist.

## Append-only framing

MemoryPack payloads are not self-delimiting on a byte stream, so each event is
stored as:

```text
4-byte little-endian unsigned payload length
MemoryPack event payload
```

Every append opens the file without truncation, seeks to its current end, and
writes one new frame. Existing bytes are never rewritten.

The event payload is produced with `memorypack.encodeTo`. During replay, each
frame is exposed through a reader that may return partial chunks and decoded
with `memorypack.decodeFromReader`. This is the same streaming API used by the
library's streaming tests.

If the final frame is incomplete, replay prints a warning and ignores that
final frame. Earlier complete events remain available.

## Event schema

```text
Event union
  tag 0: Opened { owner: Str }
  tag 1: Deposited { amount: int64 }
  tag 2: Withdrew { amount: int64 }
```

The derived state contains the account owner, balance, and number of replayed
events. Events use only a tagged union, objects, `Str`, and `int64`, with no
unordered collections.

## Commands

```text
open <owner>
deposit <positive-amount>
withdraw <positive-amount>
replay
state
```

`state` is an alias for `replay`. Separate invocations append to and replay the
same log file, demonstrating persistence through event history.

## Example output

```text
=== Empty event-sourced account ===
account not opened, balance=0, events=0

=== Append account opening and first transactions ===
Appended open event.
Appended deposit event.
Appended withdraw event.
--- replay after first process runs ---
owner=Ada, balance=70, events=3

=== Append another transaction in a later process ===
Appended deposit event.
--- replay after appending to the existing log ---
owner=Ada, balance=95, events=4
```
