# memorypack-zig

`memorypack-zig` implements a defined, tested subset of
[Cysharp/MemoryPack](https://github.com/Cysharp/MemoryPack)'s binary wire
format. The interop harness under `interop/` runs the real C# `MemoryPack`
NuGet package and verifies both directions byte-for-byte.

The format is schema-based and is not self-describing. Zig and C# declarations
must use the same member order, widths, and MemoryPack category.

## Zig/C# mapping

- Zig `extern struct`, recursively composed only of fixed unmanaged values,
  maps to a C# unmanaged sequential `struct`. It uses the struct's native
  layout, including padding, with no header.
- Zig regular/auto-layout `struct` maps to a C# `[MemoryPackable] partial
  class` or record. It uses Object format and starts with a one-byte member
  count.
- Zig `?T` maps to C# nullable values or nullable objects. Nullable objects use
  the Object `255` null header. Nullable unmanaged values use MemoryPack's
  nullable formatter: an `i32` presence value (`0` or `1`) followed by the
  value slot; null still carries a zero value slot.
- Zig `[]T` and `?[]T` map to C# `T[]`/collection values. They use a signed
  little-endian `i32` length, with `-1` meaning null.
- `memorypack.KeyValue(K, V)` maps to C# `KeyValuePair<K, V>` and uses Tuple
  framing with no header. `memorypack.Dictionary(K, V)` is the deterministic
  slice-of-key-values representation for C# dictionaries.
- Zig tagged `union(enum)` maps to a C# MemoryPack union interface and uses
  the enum tag values as MemoryPack union tags.
- A version-tolerant Zig object opts in by declaring
  `pub const memorypack_version_tolerant = true;`. It maps to
  `[MemoryPackable(GenerateType.VersionTolerant)]`; each member is length
  prefixed so readers can skip unknown fields.
- A circular-reference Zig object declares
  `pub const memorypack_circular_reference = true;` and is referenced through
  `*T` or `?*T`. It maps to
  `[MemoryPackable(GenerateType.CircularReference)]`; pointer identity is
  preserved during encode, decode, and `deinit`.
- Built-in formatter newtypes are provided for `Guid`, `DateTime`,
  `DateTimeOffset`, `TimeSpan`, `Decimal`, `Version`, and `Uri`. They use the
  corresponding MemoryPack layouts rather than ordinary Zig struct framing.
- Native Zig `i128`, `u128`, and `f16` map directly to C# `Int128`, `UInt128`,
  and `Half`.
- `memorypack.Array(rank, T)` represents a rank-`rank` C# multidimensional
  array with explicit dimensions and a flat row-major value slice.
  `memorypack.Array2(T)` remains as a rank-2 alias.
- `memorypack.Tuple3(...)` and `memorypack.Tuple4(...)` represent C#
  `ValueTuple` values with three and four elements. User-defined structs
  marked `memorypack_tuple` support other arities.
- `memorypack_ignore_<field>` and `memorypack_include_only`/
  `memorypack_include_<field>` declarations control member selection.
- `encodeTo` writes an encoded value to any sink exposing `writeAll`;
  `decodeFromReader` accepts any reader exposing `read` and buffers the stream
  before using the existing slice decoder.
- `decodeInto` overwrites an existing value. Fixed-width slices with matching
  lengths reuse their existing allocation; other values are safely replaced
  with ownership-aware cleanup.
- Explicit ordering is enabled with `memorypack_explicit = true`,
  `memorypack_explicit_count`, and `memorypack_order_<field>` declarations.
- `memorypack.Str` is the explicit Zig string type and maps to C# `string`.
  Plain `[]u8` and `[]const u8` map to C# `byte[]`.
- Zig integer, float, bool, and enum widths map directly to the corresponding
  C# primitive/tag type.

Because `[]const u8` is otherwise ambiguous, strings must use `Str`:

```zig
const User = struct {
    id: i32,
    name: ?memorypack.Str,
    payload: []const u8,
};
```

## Wire format

All values are little-endian. The implementation requires a little-endian
host, matching the C# reference implementation.

- **Unmanaged struct:** raw struct memory, including padding; no header.
- **Object:** one unsigned byte member count (`0`–`249`), followed by members
  in declaration order. `255` is null.
- **Typecode varint:** values `0`–`127` and `-1`–`-120` are encoded directly
  as one byte. Larger values use typecodes `-121` through `-128` for `u8`,
  `i8`, `u16`, `i16`, `u32`, `i32`, `u64`, and `i64`, respectively, followed
  by the little-endian payload.
- **Collection:** signed little-endian `i32` element count, followed by
  elements. `-1` is null. `byte[]` uses the same count followed by raw bytes.
- **Tuple:** tuple members are serialized consecutively with no header. This
  includes `KeyValuePair<K, V>`, `ValueTuple`, and the Zig `KeyValue`/
  `Tuple3`/`Tuple4` types.
- **Union:** a tag from `0` through `249` is one byte followed by the payload.
  Tag `250` is followed by a little-endian `u16` tag and then the payload.
  `255` represents a nullable union. The Zig union tag enum controls these
  numeric tags, including tags requiring the `250` escape.
- **Dictionary:** a dictionary is a Collection of Tuple key/value pairs.
  Empty and single-entry dictionaries can be byte-identical across languages.
  C# dictionary enumeration order is not guaranteed, so multi-entry
  dictionaries must be compared by field equality rather than raw bytes.
- **Multi-dimensional array:** rank `N` uses Object header `N+1`, `N` i32
  dimensions, an i32 total element count, and row-major values. The Zig
  `Array(N, T)` representation matches this framing.
- **Immutable collections and sets:** C# `ImmutableArray<T>` and `HashSet<T>`
  use the same Collection framing as arrays and lists. Zig emits these as
  deterministic slices; set ordering is not guaranteed across implementations.
- **String:** `-1` is null and `0` is empty. The writer uses MemoryPack's
  UTF-8 form: `i32 ~utf8ByteCount`, `i32 utf16Length`, then UTF-8 bytes. The
  reader accepts both this form and the UTF-16 form.
- **Primitives:** little-endian native-width integers and floats, one-byte
  booleans, enums encoded as their tag integer, and 16-byte little-endian
  `Int128`/`UInt128` values plus 2-byte `Half` values.
- **Nullable unmanaged values:** `i32` presence (`0`/`1`) followed by the
  value slot, including a zero slot when absent.
- **Version-tolerant object:** member count, one typecode-varint byte length
  for each member, then member values. `255` is null. Readers decode the
  fields they know, skip extra fields using their lengths, and zero-fill
  fields absent from older data.
- **Circular-reference object:** first occurrences use version-tolerant
  framing followed by a typecode-varint reference ID; repeated pointers use
  `(250, reference ID)`. IDs are assigned from zero in traversal order.
  Decoding stores allocated objects before reading their fields, allowing
  genuine cycles. `deinit` tracks pointer identities and frees each object
  once.
- **Member selection:** ignored fields are omitted from the member count and
  default-filled by the reader. Include-only declarations select the fields
  that remain serialized.
- **Built-in formatters:** `Guid` uses .NET's mixed-endian first three fields;
  `DateTime` is raw `_dateData`; `DateTimeOffset` is offset minutes followed
  by local ticks; `TimeSpan` is i64 ticks; `Decimal` is flags, hi, lo, mid;
  `Version` is an Object with four i32 members; `DateOnly` is an i32 day
  number; `TimeOnly` is an i64 tick count; `BitArray` uses Object header `2`,
  an i32 bit length, a Collection count of packed u32 words, and little-endian
  word payloads; `StringBuilder` uses positive-length UTF-16 String framing;
  `Complex` is real f64 followed by imaginary f64; and `Uri` uses String
  framing.
- **Special built-ins:** `CultureInfo` and `TypeName` use String framing.
  `TypeName` is an opaque type-name string: Zig never resolves or loads the
  named type. Resolving arbitrary deserialized type names is a security risk and
  must remain the caller's explicit responsibility. `IPAddress` has a Zig
  byte-collection representation, but MemoryPack 1.21.3 does not register an
  `IPAddress` formatter in its default provider, so no C# wire vector is
  claimed for it.
- **Explicit layout:** fields are emitted by their numeric order and the
  member count is the configured maximum order plus one. Missing Zig slots
  emit a zero byte. MemoryPack 1.21.3 rejects non-contiguous
  `MemoryPackOrder` values in its source generator, so gap slots cannot be
  produced by the C# harness; contiguous explicit ordering is byte-tested
  against C#.

## Serialization callbacks

Object-mapped Zig structs may declare pointer callbacks:

```zig
pub fn memorypackOnSerializing(self: *Self) void {}
pub fn memorypackOnSerialized(self: *Self) void {}
pub fn memorypackOnDeserializing(self: *Self) void {}
pub fn memorypackOnDeserialized(self: *Self) void {}
```

They run before and after the corresponding encode/decode operation. Callback
methods are not serialized and therefore do not change wire bytes.

Streaming decode buffers arbitrary reader chunk sizes, including one- and
two-byte reads, before invoking the same slice decoder. The chunked-reader
tests cover nested objects and collections.

## Benchmarks

Run the indicative benchmark with:

```text
zig build bench -Doptimize=ReleaseFast
```

The benchmark uses one retained-capacity arena allocator for each operation
class, reset between iterations, so MemoryPack and `std.json` use comparable
allocation/reclamation strategies. One development-machine run reported:

```text
MemoryPack unmanaged: 8269.17 MiB/s (178 ns/op, 1540 bytes/op)
MemoryPack object: 342.26 MiB/s (7501 ns/op, 2692 bytes/op)
std.json: 121.94 MiB/s (23956 ns/op, 3063 bytes/op)
```

The object result is substantially faster than `std.json` under this fair
comparison. The earlier object result was a benchmark artifact: it used the
page allocator and freed every decoded object/string allocation individually,
while `std.json`'s parsed representation was reclaimed through its aggregate
parsed allocator. These numbers remain machine-, allocator-, compiler-, and
dataset-dependent.

All eight supported MemoryPack categories are now covered by the Zig tests and
the real C# interop harness. Unsupported types produce a compile error or
invalid-data error rather than malformed output.

`BigInteger` is intentionally not included. Investigation against MemoryPack
1.21.3 showed its formatter writes `value.TryWriteBytes(temp)` followed by
`temp.Slice(written)`, producing a collection of the unused zero-filled tail
(for example, `-12345` produced a 253-byte zero payload and deserialized as
zero). Supporting arbitrary BigInteger values would therefore reproduce a
runtime formatter defect rather than a stable value-preserving format.

## API

```zig
const bytes = try memorypack.encode(gpa, value);
defer gpa.free(bytes);

var value = try memorypack.decode(MyType, gpa, bytes);
defer memorypack.deinit(MyType, gpa, &value);
```

`Writer` and `Reader` expose the streaming primitives used by the one-shot
helpers.

## Cross-language verification

The harness installs no fake serializer: it references the real
`MemoryPack` NuGet package.

```sh
export PATH="$HOME/.bin:$HOME/.local/bin:$HOME/.asdf/shims:$PATH"
./interop/run.sh
zig build test
zig build run
zig fmt --check src build.zig
```

`interop/run.sh` generates C# golden vectors, copies them into
`src/vectors/` for the Zig test suite, runs `zig build test`, emits matching
Zig vectors, and asks C# MemoryPack to deserialize and reserialize every Zig
vector.
