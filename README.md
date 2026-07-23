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
  is the format used by `KeyValuePair<K, V>` and by the Zig `KeyValue` type.
- **Union:** a tag from `0` through `249` is one byte followed by the payload.
  Tag `250` is followed by a little-endian `u16` tag and then the payload.
  `255` represents a nullable union. The Zig union tag enum controls these
  numeric tags, including tags requiring the `250` escape.
- **Dictionary:** a dictionary is a Collection of Tuple key/value pairs.
  Empty and single-entry dictionaries can be byte-identical across languages.
  C# dictionary enumeration order is not guaranteed, so multi-entry
  dictionaries must be compared by field equality rather than raw bytes.
- **String:** `-1` is null and `0` is empty. The writer uses MemoryPack's
  UTF-8 form: `i32 ~utf8ByteCount`, `i32 utf16Length`, then UTF-8 bytes. The
  reader accepts both this form and the UTF-16 form.
- **Primitives:** little-endian native-width integers and floats, one-byte
  booleans, and enums encoded as their tag integer.
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

All eight supported MemoryPack categories are now covered by the Zig tests and
the real C# interop harness. Unsupported types produce a compile error or
invalid-data error rather than malformed output.

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
