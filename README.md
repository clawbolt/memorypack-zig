[English](README.md) | [中文](README.zh-CN.md)

# memorypack-zig

`memorypack-zig` is a Zig implementation of the binary wire format used by
[Cysharp/MemoryPack](https://github.com/Cysharp/MemoryPack). It targets a
defined, tested subset and proves binary compatibility with the real C#
MemoryPack 1.21.3 implementation in both directions.

MemoryPack is a schema-based, zero-copy-oriented binary serializer for .NET.
The format is not self-describing: Zig and C# declarations must agree on
member order, widths, and MemoryPack category.

## Quick start

The repository currently builds as a standalone Zig package. To use it from
another project, add this repository as a dependency in `build.zig`, expose
the `memorypack` module, and import it:

```zig
const memorypack = @import("memorypack");
```

Minimal encode/decode:

```zig
const std = @import("std");
const memorypack = @import("memorypack");

const User = struct {
    id: i32,
    name: memorypack.Str,
};

pub fn main() !void {
    const gpa = std.heap.page_allocator;
    const input = User{ .id = 7, .name = .{ .bytes = "Ada" } };

    const bytes = try memorypack.encode(gpa, input);
    defer gpa.free(bytes);

    var output = try memorypack.decode(User, gpa, bytes);
    defer memorypack.deinit(User, gpa, &output);
}
```

## Usage

### Objects and unmanaged values

Regular Zig structs use Object framing: a one-byte member count followed by
the fields in declaration order.

```zig
const User = struct {
    id: i32,
    name: memorypack.Str,
};
```

An `extern struct` composed only of fixed unmanaged fields uses the raw-copy
fast path, including native padding and with no header:

```zig
const Raw = extern struct {
    id: u64,
    score: f64,
};
```

### Collections, strings, and nullable values

Slices use Collection framing (`i32` count, with `-1` for null). Use `Str`
when the value is a C# `string`; plain byte slices are `byte[]`.

```zig
const values: []const i32 = &.{ 1, 2, 3 };
const text = memorypack.Str{ .bytes = "hello" };
const maybe_text: ?memorypack.Str = null;

const bytes = try memorypack.encode(gpa, values);
defer gpa.free(bytes);
```

Nullable objects use the Object null marker. Nullable unmanaged values use
MemoryPack's presence-plus-value representation.

### Tuples, unions, and dictionaries

`KeyValue` maps to `KeyValuePair`; `Tuple3` and `Tuple4` map to
`ValueTuple`. Tuple members have no header.

```zig
const pair = memorypack.KeyValue(i32, memorypack.Str){
    .key = 1,
    .value = .{ .bytes = "one" },
};
const triple = memorypack.Tuple3(i32, memorypack.Str, bool){
    .item0 = 7,
    .item1 = .{ .bytes = "seven" },
    .item2 = true,
};
```

Tagged unions use their enum values as MemoryPack union tags. Tags below 250
use one byte; larger tags use the `250` plus little-endian `u16` escape.

```zig
const MessageTag = enum(u16) {
    number = 0,
    text = 1,
};

const Message = union(MessageTag) {
    number: i32,
    text: memorypack.Str,
};
```

`Dictionary(K, V)` is the deterministic Zig representation: a slice of
`KeyValue(K, V)`.

```zig
const entries: memorypack.Dictionary(i32, memorypack.Str) = &.{
    .{ .key = 1, .value = .{ .bytes = "one" } },
};
```

### Version tolerance and circular references

Opt into version-tolerant Object framing with a type declaration:

```zig
const Versioned = struct {
    pub const memorypack_version_tolerant = true;
    id: i32,
    name: ?memorypack.Str,
};
```

Each member is length-prefixed, allowing readers to skip extra members and
zero-fill members absent from older data.

Circular-reference objects use pointer identity and the same length-aware
framing:

```zig
const Node = struct {
    pub const memorypack_circular_reference = true;
    value: i32,
    next: ?*Node,
};

const node = try gpa.create(Node);
node.* = .{ .value = 42, .next = node };
defer gpa.destroy(node);

const bytes = try memorypack.encode(gpa, node);
defer gpa.free(bytes);

var decoded = try memorypack.decode(*Node, gpa, bytes);
defer memorypack.deinit(*Node, gpa, &decoded);
```

### Explicit layout, callbacks, and member selection

Explicit ordering uses declarations named after each field:

```zig
const Explicit = struct {
    pub const memorypack_explicit = true;
    pub const memorypack_explicit_count = 2;
    pub const memorypack_order_first = 0;
    pub const memorypack_order_second = 1;

    first: i32,
    second: memorypack.Str,
};
```

Object callbacks are optional pointer methods:

```zig
pub fn memorypackOnSerializing(self: *Self) void {}
pub fn memorypackOnSerialized(self: *Self) void {}
pub fn memorypackOnDeserializing(self: *Self) void {}
pub fn memorypackOnDeserialized(self: *Self) void {}
```

Ignore fields with `memorypack_ignore_<field>`. For include-only behavior,
set `memorypack_include_only` and mark each retained field:

```zig
const Selected = struct {
    pub const memorypack_ignore_debug = true;
    pub const memorypack_include_only = true;
    pub const memorypack_include_id = true;
    pub const memorypack_include_name = true;

    id: i32,
    name: memorypack.Str,
    debug: i32,
};
```

Ignored fields do not contribute to member count and are default-filled while
decoding.

### Streaming and overwrite-deserialize

`encodeTo` accepts any sink with `writeAll(bytes)`. `decodeFromReader` accepts
any reader with `read(buffer)`; it buffers the stream and then uses the same
slice decoder:

```zig
try memorypack.encodeTo(gpa, input, sink);
var output = try memorypack.decodeFromReader(User, gpa, reader);
defer memorypack.deinit(User, gpa, &output);
```

To overwrite an existing value, use:

```zig
try memorypack.decodeInto(User, gpa, bytes, &existing);
```

Fixed-width slices with matching lengths reuse their allocation. Other values
are replaced with ownership-aware cleanup.

### Built-in types

The following public representations have dedicated formatters:

| Zig representation | C# type | Wire mapping |
| --- | --- | --- |
| `Guid` | `Guid` | .NET mixed-endian 16-byte layout |
| `DateTime` | `DateTime` | Raw `_dateData` `i64` |
| `DateTimeOffset` | `DateTimeOffset` | Offset minutes, then local ticks |
| `TimeSpan` | `TimeSpan` | Tick `i64` |
| `Decimal` | `decimal` | `flags`, `hi`, `lo`, `mid` `i32`s |
| `Version` | `Version` | Object with four `i32` members |
| `Uri` | `Uri` | String framing |
| `DateOnly` | `DateOnly` | Day-number `i32` |
| `TimeOnly` | `TimeOnly` | Tick `i64` |
| `BitArray` | `BitArray` | Object header, bit length, packed `u32` words |
| `StringBuilder` | `StringBuilder` | Positive-length UTF-16 String |
| `Complex` | `Complex` | Real `f64`, imaginary `f64` |
| `CultureInfo` | `CultureInfo` | Culture name String |
| `TypeName` | `Type` | Opaque type-name String |

Native `i128`, `u128`, and `f16` map directly to C# `Int128`, `UInt128`, and
`Half`.

## Supported formats and wire mapping

| Zig form | MemoryPack category |
| --- | --- |
| Fixed `extern struct` | Raw unmanaged bytes, including padding |
| Regular `struct` | Object: one-byte member count plus fields |
| `[]T`, `?[]T` | Collection: signed `i32` count; `-1` is null |
| `Str`, `?Str` | String framing |
| `KeyValue`, `Tuple3`, `Tuple4` | Headerless Tuple |
| `Dictionary(K, V)` | Collection of Tuple key/value pairs |
| `union(enum)` | Union tag plus payload |
| `Array(rank, T)` | Rank plus dimensions, count, row-major values |
| Version-tolerant struct | Member count, typecode-varint lengths, values |
| Circular-reference pointer | Length-aware object plus reference IDs |
| Built-in marker structs | Dedicated MemoryPack formatter |

All values are little-endian and require a little-endian host.

### Wire details and ordering caveats

- Typecode varints encode `0..127` and `-1..-120` directly; typecodes
  `-121..-128` select `u8`, `i8`, `u16`, `i16`, `u32`, `i32`, `u64`, and `i64`.
- Tuple values have no header.
- Union tags `0..249` are one byte; tag `250` is followed by a little-endian
  `u16`; `255` is the nullable-union marker.
- Rank `N` multidimensional arrays use Object header `N+1`, `N` dimensions,
  an `i32` flattened count, then row-major values.
- Immutable arrays, lists, queues, stacks, linked lists, read-only
  collections, and sets use Collection framing. Enumeration order still
  matters for byte equality.
- Empty and single-entry dictionaries are deterministic in the harness.
  Multi-entry dictionaries and sets should generally be compared by field or
  set equality rather than raw bytes.
- `StringBuilder` uses positive-length UTF-16 framing; normal `Str` writing
  uses MemoryPack's UTF-8 form and the reader accepts both forms.

## Interop verification

The harness uses the real MemoryPack 1.21.3 NuGet package; it does not use a
fake serializer. Run:

```sh
export PATH="$HOME/.dotnet:$HOME/.bin:$HOME/.local/bin:$HOME/.asdf/shims:$PATH"
./interop/run.sh
```

The script:

1. Generates C# golden vectors under `interop/vectors/`.
2. Copies them to `src/vectors/` for embedded Zig tests.
3. Runs `zig build test`.
4. Emits matching Zig vectors under the ignored `interop/zig_vectors/`.
5. Has C# deserialize and reserialize the Zig vectors.

Deterministic cases require byte equality in both directions. Nondeterministic
collection ordering uses semantic equality where appropriate.

## Benchmarks

Run:

```sh
zig build bench -Doptimize=ReleaseFast
```

The benchmark uses one retained-capacity arena allocator per operation class,
reset between iterations, so MemoryPack and `std.json` use comparable
allocation/reclamation strategies. One development-machine run reported:

```text
MemoryPack unmanaged: 8520.63 MiB/s (172 ns/op, 1540 bytes/op)
MemoryPack object: 356.34 MiB/s (7205 ns/op, 2692 bytes/op)
std.json: 130.81 MiB/s (22332 ns/op, 3063 bytes/op)
```

These numbers are machine-, allocator-, compiler-, and dataset-dependent.

## Known limitations and exclusions

- `BigInteger` is intentionally excluded. MemoryPack 1.21.3's formatter uses
  `temp.Slice(written)` after `TryWriteBytes`, writing the unused zero-filled
  tail and losing the value. Zig does not reproduce this defect.
- `IPAddress` is represented on the Zig side, but the default MemoryPack 1.21.3
  provider reports `System.Net.IPAddress is not registered in this provider`.
  Consequently there is no claimed C# vector for it.
- MemoryPack 1.21.3 rejects non-contiguous `MemoryPackOrder` values in its C#
  source generator (`MEMPACK026`), although Zig can represent gap slots.
- Dictionary, set, and other unordered collection enumeration is not
  byte-stable across implementations.
- The format is schema-based; unsupported types fail rather than producing
  silently incompatible bytes.
- Resolving arbitrary `TypeName` values is intentionally outside this library.
  Treat them as untrusted strings and do not dynamically load types without an
  application-level security policy.

## API summary

```zig
pub fn encode(gpa: Allocator, value: anytype) Error![]u8
pub fn decode(comptime T: type, gpa: Allocator, bytes: []const u8) Error!T
pub fn encodeTo(gpa: Allocator, value: anytype, sink: anytype) Error!void
pub fn decodeFromReader(comptime T: type, gpa: Allocator, reader: anytype) Error!T
pub fn decodeInto(comptime T: type, gpa: Allocator, bytes: []const u8, target: *T) Error!void
pub fn deinit(comptime T: type, gpa: Allocator, value: *T) void
```

## Development

```sh
export PATH="$HOME/.dotnet:$HOME/.bin:$HOME/.local/bin:$HOME/.asdf/shims:$PATH"
zig build test
zig fmt --check src build.zig
./interop/run.sh
```

## Example / real-world usage

The file-based player-profile example demonstrates a complete Zig → C# →
Zig workflow using real MemoryPack 1.21.3:

```sh
./examples/player-profile/run.sh
```

It covers objects, enums, a nullable application-defined value, arrays, and a tagged event
union without relying on unordered collection ordering. See
[`examples/player-profile/README.md`](examples/player-profile/README.md).

For a live TCP example, see
[`examples/rpc-socket/README.md`](examples/rpc-socket/README.md). It runs a
real C# MemoryPack RPC server and a Zig client with explicit length-prefix
framing.

For a pure-Zig application, see
[`examples/task-cli/README.md`](examples/task-cli/README.md). It is a
persistent command-line task manager whose store is encoded with MemoryPack.

For a streaming/event-sourcing example, see
[`examples/event-log/README.md`](examples/event-log/README.md). It appends
framed MemoryPack events and rebuilds a bank ledger by replaying the log.

For a larger embedded-database example, see
[`examples/zdb/README.md`](examples/zdb/README.md). It combines a MemoryPack
snapshot, durable framed WAL, crash recovery, compaction, secondary indexing,
and version-tolerant documents.
