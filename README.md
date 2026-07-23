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
  in declaration order. `255` is null. Circular-reference marker `250` is
  deliberately unsupported.
- **Collection:** signed little-endian `i32` element count, followed by
  elements. `-1` is null. `byte[]` uses the same count followed by raw bytes.
- **String:** `-1` is null and `0` is empty. The writer uses MemoryPack's
  UTF-8 form: `i32 ~utf8ByteCount`, `i32 utf16Length`, then UTF-8 bytes. The
  reader accepts both this form and the UTF-16 form.
- **Primitives:** little-endian native-width integers and floats, one-byte
  booleans, and enums encoded as their tag integer.
- **Nullable unmanaged values:** `i32` presence (`0`/`1`) followed by the
  value slot, including a zero slot when absent.

The following MemoryPack categories are intentionally not implemented:
unions/polymorphism, version-tolerant objects, circular references,
tuples/`KeyValuePair`, and dictionaries/maps. Unsupported types produce a
compile error or invalid-data error rather than malformed output.

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
