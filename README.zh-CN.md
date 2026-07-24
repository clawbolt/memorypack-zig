[English](README.md) | [中文](README.zh-CN.md)

# memorypack-zig

`memorypack-zig` 是
[Cysharp/MemoryPack](https://github.com/Cysharp/MemoryPack) 二进制线格式的
Zig 实现。项目实现并测试了一个明确的子集，并使用真实的 C#
MemoryPack 1.21.3 验证双向二进制兼容性。

MemoryPack 是 .NET 生态中一种基于 schema、面向零拷贝的二进制序列化器。
其格式不是自描述的：Zig 与 C# 的声明必须在成员顺序、宽度和 MemoryPack
类别上保持一致。

## 快速开始

当前仓库可以作为独立 Zig 项目构建。要在其他项目中使用，请在
`build.zig` 中添加本仓库作为依赖，暴露 `memorypack` 模块，然后导入：

```zig
const memorypack = @import("memorypack");
```

最小的编码/解码示例：

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

## 使用方式

### 对象与非托管值

普通 Zig struct 使用 Object framing：先写入一个字节的成员数量，再按声明
顺序写入成员。

```zig
const User = struct {
    id: i32,
    name: memorypack.Str,
};
```

只包含固定非托管字段的 `extern struct` 使用原始拷贝快速路径，包括原生
内存布局中的 padding，且不带 header：

```zig
const Raw = extern struct {
    id: u64,
    score: f64,
};
```

### 集合、字符串与可空值

切片使用 Collection framing（`i32` 数量，`-1` 表示 null）。当值对应 C#
的 `string` 时使用 `Str`；普通字节切片对应 `byte[]`。

```zig
const values: []const i32 = &.{ 1, 2, 3 };
const text = memorypack.Str{ .bytes = "hello" };
const maybe_text: ?memorypack.Str = null;

const bytes = try memorypack.encode(gpa, values);
defer gpa.free(bytes);
```

可空对象使用 Object 的 null 标记。可空非托管值使用 MemoryPack 的
presence 加 value 表示。

### Tuple、Union 与 Dictionary

`KeyValue` 对应 `KeyValuePair`；`Tuple3` 与 `Tuple4` 对应 `ValueTuple`。
Tuple 成员不带 header。

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

带标签的 union 使用其 enum 值作为 MemoryPack union tag。小于 250 的标签
使用一个字节；更大的标签使用 `250` 加小端序 `u16` 转义形式。

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

`Dictionary(K, V)` 是确定性的 Zig 表示：一个 `KeyValue(K, V)` 切片。

```zig
const entries: memorypack.Dictionary(i32, memorypack.Str) = &.{
    .{ .key = 1, .value = .{ .bytes = "one" } },
};
```

### 版本容错与循环引用

通过类型声明启用版本容错的 Object framing：

```zig
const Versioned = struct {
    pub const memorypack_version_tolerant = true;
    id: i32,
    name: ?memorypack.Str,
};
```

每个成员都会带长度前缀，因此读取器可以跳过额外成员，并为旧数据中缺少的
成员填充零值。

循环引用对象使用指针身份和相同的长度感知 framing：

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

### 显式布局、回调与成员选择

显式顺序使用以字段名命名的声明：

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

Object 回调是可选的指针方法：

```zig
pub fn memorypackOnSerializing(self: *Self) void {}
pub fn memorypackOnSerialized(self: *Self) void {}
pub fn memorypackOnDeserializing(self: *Self) void {}
pub fn memorypackOnDeserialized(self: *Self) void {}
```

使用 `memorypack_ignore_<field>` 忽略字段。若要仅包含指定字段，设置
`memorypack_include_only`，并为每个保留字段添加标记：

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

被忽略的字段不会计入成员数量，解码时会填充默认值。

### 流式处理与覆盖式反序列化

`encodeTo` 接受任何提供 `writeAll(bytes)` 的 sink。`decodeFromReader` 接受
任何提供 `read(buffer)` 的 reader；它会先缓冲输入，再调用相同的切片解码器：

```zig
try memorypack.encodeTo(gpa, input, sink);
var output = try memorypack.decodeFromReader(User, gpa, reader);
defer memorypack.deinit(User, gpa, &output);
```

要覆盖已有值，使用：

```zig
try memorypack.decodeInto(User, gpa, bytes, &existing);
```

长度相同的固定宽度切片会复用已有分配；其他值会在正确处理所有权后替换。

### 内置类型

以下公共表示具有专用 formatter：

| Zig 表示 | C# 类型 | 线格式 |
| --- | --- | --- |
| `Guid` | `Guid` | .NET 混合端序的 16 字节布局 |
| `DateTime` | `DateTime` | 原始 `_dateData` `i64` |
| `DateTimeOffset` | `DateTimeOffset` | offset 分钟，再跟本地 ticks |
| `TimeSpan` | `TimeSpan` | ticks `i64` |
| `Decimal` | `decimal` | `flags`、`hi`、`lo`、`mid` 四个 `i32` |
| `Version` | `Version` | 包含四个 `i32` 成员的 Object |
| `Uri` | `Uri` | String framing |
| `DateOnly` | `DateOnly` | day number `i32` |
| `TimeOnly` | `TimeOnly` | ticks `i64` |
| `BitArray` | `BitArray` | Object header、位长度、打包的 `u32` words |
| `StringBuilder` | `StringBuilder` | 正长度 UTF-16 String |
| `Complex` | `Complex` | real `f64`、imaginary `f64` |
| `CultureInfo` | `CultureInfo` | culture name String |
| `TypeName` | `Type` | 不透明的类型名 String |

原生 Zig `i128`、`u128` 和 `f16` 分别直接对应 C# `Int128`、`UInt128` 和
`Half`。

## 支持的格式与类型映射

| Zig 形式 | MemoryPack 类别 |
| --- | --- |
| 固定的 `extern struct` | 原始非托管字节，包括 padding |
| 普通 `struct` | Object：一个字节的成员数量加字段 |
| `[]T`、`?[]T` | Collection：有符号 `i32` 数量，`-1` 表示 null |
| `Str`、`?Str` | String framing |
| `KeyValue`、`Tuple3`、`Tuple4` | 无 header 的 Tuple |
| `Dictionary(K, V)` | 由 Tuple key/value 组成的 Collection |
| `union(enum)` | Union tag 加 payload |
| `Array(rank, T)` | rank 加维度、数量和行主序值 |
| 版本容错 struct | 成员数量、typecode-varint 长度和值 |
| 循环引用指针 | 带长度信息的对象加引用 ID |
| 带内置标记的 struct | 专用 MemoryPack formatter |

所有值均使用小端序，并要求运行在小端主机上。

### 线格式细节与顺序注意事项

- Typecode varint 对 `0..127` 和 `-1..-120` 直接编码；typecode
  `-121..-128` 分别选择 `u8`、`i8`、`u16`、`i16`、`u32`、`i32`、`u64`
  和 `i64`。
- Tuple 值不带 header。
- Union tag `0..249` 占一个字节；tag `250` 后跟小端序 `u16`；`255` 是
  可空 union 标记。
- rank 为 `N` 的多维数组使用 Object header `N+1`、`N` 个维度、一个
  `i32` 展平数量，然后是行主序值。
- Immutable array、list、queue、stack、linked list、只读集合和 set 都使用
  Collection framing。枚举顺序仍会影响字节相等性。
- 测试 harness 中空字典和单元素字典是确定性的。多元素字典和 set 通常应
  比较字段或集合相等性，而不是比较原始字节。
- `StringBuilder` 使用正长度 UTF-16 framing；普通 `Str` 写入使用
  MemoryPack 的 UTF-8 形式，读取器接受两种形式。

## 跨语言互操作验证

Harness 使用真实的 MemoryPack 1.21.3 NuGet 包，不是伪造的 serializer。运行：

```sh
export PATH="$HOME/.dotnet:$HOME/.bin:$HOME/.local/bin:$HOME/.asdf/shims:$PATH"
./interop/run.sh
```

脚本会：

1. 在 `interop/vectors/` 生成 C# golden vectors。
2. 将它们复制到 `src/vectors/`，供 Zig 测试嵌入。
3. 运行 `zig build test`。
4. 在被忽略的 `interop/zig_vectors/` 中生成匹配的 Zig vectors。
5. 让 C# MemoryPack 反序列化并重新序列化所有 Zig vectors。

确定性的 case 要求双向字节完全相等；对于顺序不确定的集合，在适当场景
使用语义相等性。

## 基准测试

运行：

```sh
zig build bench -Doptimize=ReleaseFast
```

基准测试为每种操作使用一个保留容量的 arena allocator，并在每次迭代间
reset，因此 MemoryPack 和 `std.json` 使用可比较的分配/回收策略。一次在
开发机器上的运行结果：

```text
MemoryPack unmanaged: 8520.63 MiB/s (172 ns/op, 1540 bytes/op)
MemoryPack object: 356.34 MiB/s (7205 ns/op, 2692 bytes/op)
std.json: 130.81 MiB/s (22332 ns/op, 3063 bytes/op)
```

这些数字取决于机器、allocator、编译器和数据集。

## 已知限制与排除项

- `BigInteger` 有意排除。MemoryPack 1.21.3 的 formatter 在
  `TryWriteBytes` 后使用 `temp.Slice(written)`，写入了未使用的全零尾部并
  丢失原值。Zig 不会复制这个缺陷。
- Zig 侧提供 `IPAddress` 表示，但默认 MemoryPack 1.21.3 provider 报告
  `System.Net.IPAddress is not registered in this provider`，因此不声称有
  该类型的 C# vector。
- MemoryPack 1.21.3 的 C# source generator 拒绝非连续的
  `MemoryPackOrder`（`MEMPACK026`），虽然 Zig 可以表示 gap slot。
- Dictionary、set 及其他无序集合的枚举顺序在不同实现间不保证相同，因此
  原始字节不一定稳定。
- 该格式基于 schema；不支持的类型会失败，而不是静默产生不兼容字节。
- 解析任意 `TypeName` 不属于本库职责。应将其视为不可信字符串，不要在没有
  应用层安全策略的情况下动态加载类型。

## API 摘要

```zig
pub fn encode(gpa: Allocator, value: anytype) Error![]u8
pub fn decode(comptime T: type, gpa: Allocator, bytes: []const u8) Error!T
pub fn encodeTo(gpa: Allocator, value: anytype, sink: anytype) Error!void
pub fn decodeFromReader(comptime T: type, gpa: Allocator, reader: anytype) Error!T
pub fn decodeInto(comptime T: type, gpa: Allocator, bytes: []const u8, target: *T) Error!void
pub fn deinit(comptime T: type, gpa: Allocator, value: *T) void
```

## 开发

```sh
export PATH="$HOME/.dotnet:$HOME/.bin:$HOME/.local/bin:$HOME/.asdf/shims:$PATH"
zig build test
zig fmt --check src build.zig
./interop/run.sh
```

## 示例 / 实际使用

基于文件的 player-profile 示例展示了完整的 Zig → C# → Zig 流程，并使用
真实的 MemoryPack 1.21.3：

```sh
./examples/player-profile/run.sh
```

示例覆盖对象、枚举、可空的应用自定义值、数组和带标签的事件 union，同时不依赖
无序集合的枚举顺序。详见
[`examples/player-profile/README.md`](examples/player-profile/README.md)。

实时 TCP 示例见
[`examples/rpc-socket/README.md`](examples/rpc-socket/README.md)。它运行真实的
C# MemoryPack RPC 服务器和 Zig 客户端，并使用显式长度前缀分帧。

纯 Zig 应用示例见
[`examples/task-cli/README.md`](examples/task-cli/README.md)。这是一个持久化的
命令行任务管理器，其存储使用 MemoryPack 编码。

流式 API / 事件溯源示例见
[`examples/event-log/README.md`](examples/event-log/README.md)。它追加带帧的
MemoryPack 事件，并通过重放日志重建银行账本状态。

更完整的生产导向嵌入式数据库示例见
[`examples/zdb/README.md`](examples/zdb/README.md)。它结合了带 CRC 校验的
MemoryPack WAL、崩溃安全快照、恢复、压缩、二级索引、分页、并发和 TCP 服务。
