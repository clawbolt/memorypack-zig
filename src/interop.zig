const std = @import("std");
const memorypack = @import("memorypack.zig");

const Padded = extern struct { a: u8, b: i32 };
const BasicObject = struct { id: i32, name: ?memorypack.Str };
const NestedObject = struct { inner: ?BasicObject, values: ?[]const i32 };
const Level = enum(u8) { novice = 2, expert = 7 };
const RichObject = struct { id: u64, name: ?memorypack.Str, data: ?[]const u8, level: Level, child: ?BasicObject };
const TuplePair = memorypack.KeyValue(i32, memorypack.Str);
const TextMessage = struct { value: ?memorypack.Str };
const LargeMessage = struct { value: i32 };
const UnionTag = enum(u16) { number = 0, text = 1, large = 300 };
const MessageUnion = union(UnionTag) {
    number: BasicObject,
    text: TextMessage,
    large: LargeMessage,
};
const VersionedObject = struct {
    pub const memorypack_version_tolerant = true;
    id: i32,
    name: ?memorypack.Str,
};
const CircularNode = struct {
    pub const memorypack_circular_reference = true;
    value: i32,
    next: ?*CircularNode,
};
const ExplicitObject = struct {
    pub const memorypack_explicit = true;
    pub const memorypack_explicit_count = 2;
    pub const memorypack_order_first = 0;
    pub const memorypack_order_third = 1;
    first: i32,
    third: ?memorypack.Str,
};
const IntMatrix = memorypack.Array2(i32);
const IntCube = memorypack.Array(3, i32);
const Tuple3Value = memorypack.Tuple3(i32, memorypack.Str, bool);
const Tuple4Value = memorypack.Tuple4(i32, memorypack.Str, bool, f32);
const IgnoreObject = struct {
    pub const memorypack_ignore_ignored = true;
    kept: i32,
    ignored: i32,
};
const IncludeObject = struct {
    pub const memorypack_include_only = true;
    pub const memorypack_include_kept = true;
    pub const memorypack_include_included = true;
    kept: i32,
    included: i32,
};

fn emit(gpa: std.mem.Allocator, comptime T: type, name: []const u8, value: T) !void {
    const bytes = try memorypack.encode(gpa, value);
    defer gpa.free(bytes);
    std.debug.print("{s} ", .{name});
    for (bytes) |byte| std.debug.print("{x:0>2}", .{byte});
    std.debug.print("\n", .{});
}

pub fn main() !void {
    const gpa = std.heap.page_allocator;
    try emit(gpa, BasicObject, "object.bin", .{ .id = 42, .name = .{ .bytes = "Ada" } });
    try emit(gpa, BasicObject, "object_null_string.bin", .{ .id = -5, .name = null });
    try emit(gpa, NestedObject, "nested.bin", .{
        .inner = .{ .id = 9, .name = .{ .bytes = "inner" } },
        .values = &.{ 1, 2, 3 },
    });
    try emit(gpa, NestedObject, "nested_null_collection.bin", .{ .inner = null, .values = null });
    try emit(gpa, Padded, "padded.bin", .{ .a = 0x7f, .b = 0x12345678 });
    try emit(gpa, []const i32, "array_empty.bin", &.{});
    try emit(gpa, ?[]const i32, "array_null.bin", null);
    try emit(gpa, memorypack.Str, "string_empty.bin", .{ .bytes = "" });
    try emit(gpa, memorypack.Str, "string_unicode.bin", .{ .bytes = "héllo 🌍" });
    try emit(gpa, ?memorypack.Str, "string_null.bin", null);
    try emit(gpa, []const u8, "bytes.bin", &.{ 0, 1, 2, 255 });
    try emit(gpa, Level, "enum.bin", .expert);
    try emit(gpa, ?i32, "nullable_value.bin", 1234);
    try emit(gpa, ?i32, "nullable_value_null.bin", null);
    try emit(gpa, ?BasicObject, "nullable_object.bin", null);
    try emit(gpa, RichObject, "rich.bin", .{
        .id = 99,
        .name = .{ .bytes = "Zig" },
        .data = &.{ 8, 9, 10 },
        .level = .expert,
        .child = .{ .id = 11, .name = .{ .bytes = "child" } },
    });
    try emit(gpa, TuplePair, "tuple.bin", .{ .key = 7, .value = .{ .bytes = "seven" } });
    try emit(gpa, []const TuplePair, "dict_empty.bin", &.{});
    try emit(gpa, []const TuplePair, "dict_single.bin", &.{.{ .key = 1, .value = .{ .bytes = "one" } }});
    try emit(gpa, []const TuplePair, "dict_multi.bin", &.{
        .{ .key = 1, .value = .{ .bytes = "one" } },
        .{ .key = 2, .value = .{ .bytes = "two" } },
    });
    try emit(gpa, MessageUnion, "union_small.bin", .{ .text = .{ .value = .{ .bytes = "hello" } } });
    try emit(gpa, MessageUnion, "union_large.bin", .{ .large = .{ .value = 300 } });
    try emit(gpa, VersionedObject, "versioned.bin", .{ .id = 7, .name = .{ .bytes = "new" } });
    const node = try gpa.create(CircularNode);
    defer gpa.destroy(node);
    node.* = .{ .value = 42, .next = node };
    try emit(gpa, *CircularNode, "circular.bin", node);
    try emit(gpa, memorypack.Guid, "guid.bin", .{ .bytes = .{
        0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77,
        0x88, 0x99, 0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff,
    } });
    try emit(gpa, memorypack.DateTime, "datetime.bin", .{ .date_data = 0x48daa19ea6b30000 });
    try emit(gpa, memorypack.DateTimeOffset, "datetimeoffset.bin", .{
        .offset_minutes = 330,
        .ticks = 638162518280000000,
    });
    try emit(gpa, memorypack.TimeSpan, "timespan.bin", .{ .ticks = 123456789 });
    try emit(gpa, memorypack.Decimal, "decimal.bin", .{
        .flags = 0x40000,
        .hi = 0,
        .lo = 0x71fb04cb,
        .mid = 0x11f,
    });
    try emit(gpa, memorypack.Version, "version.bin", .{ .major = 1, .minor = 2, .build = -1, .revision = -1 });
    try emit(gpa, memorypack.Uri, "uri.bin", .{ .value = .{ .bytes = "https://example.com/a?q=1" } });
    try emit(gpa, ExplicitObject, "explicit.bin", .{ .first = 7, .third = .{ .bytes = "gap" } });
    try emit(gpa, i128, "int128.bin", -123456789012345678901234567890);
    try emit(gpa, u128, "uint128.bin", 340282366920938463463374607431768211455);
    try emit(gpa, f16, "half.bin", @as(f16, 1.5));
    try emit(gpa, IntMatrix, "array_2d.bin", .{ .dimensions = .{ 2, 2 }, .values = &.{ 1, 2, 3, 4 } });
    try emit(gpa, []const i32, "immutable_array.bin", &.{ 5, 6, 7 });
    try emit(gpa, []const i32, "hash_set.bin", &.{ 5, 6, 7 });
    try emit(gpa, IgnoreObject, "ignore.bin", .{ .kept = 7, .ignored = 99 });
    try emit(gpa, IncludeObject, "include.bin", .{ .kept = 7, .included = 11 });
    try emit(gpa, IntCube, "array_3d.bin", .{
        .dimensions = .{ 2, 2, 2 },
        .values = &.{ 1, 2, 3, 4, 5, 6, 7, 8 },
    });
    try emit(gpa, Tuple3Value, "tuple3.bin", .{ .item0 = 7, .item1 = .{ .bytes = "seven" }, .item2 = true });
    try emit(gpa, Tuple4Value, "tuple4.bin", .{
        .item0 = 7,
        .item1 = .{ .bytes = "seven" },
        .item2 = true,
        .item3 = 1.5,
    });
    try emit(gpa, memorypack.DateOnly, "date_only.bin", .{ .day_number = 738614 });
    try emit(gpa, memorypack.TimeOnly, "time_only.bin", .{ .ticks = 220280000000 });
    try emit(gpa, []const i32, "linked_list.bin", &.{ 5, 6, 7 });
    try emit(gpa, []const i32, "queue.bin", &.{ 5, 6, 7 });
    try emit(gpa, []const i32, "stack.bin", &.{ 5, 6, 7 });
    try emit(gpa, []const TuplePair, "sorted_dictionary.bin", &.{
        .{ .key = 1, .value = .{ .bytes = "one" } },
        .{ .key = 2, .value = .{ .bytes = "two" } },
    });
    try emit(gpa, []const i32, "read_only_collection.bin", &.{ 5, 6, 7 });
    try emit(gpa, memorypack.BitArray, "bit_array.bin", .{
        .bit_length = 10,
        .bytes = &.{ 0xcd, 0x01 },
    });
    try emit(gpa, memorypack.StringBuilder, "string_builder.bin", .{
        .value = .{ .bytes = "hello builder" },
    });
    try emit(gpa, memorypack.Complex, "complex.bin", .{ .real = 1.5, .imaginary = -2.25 });
    try emit(gpa, memorypack.CultureInfo, "culture_info.bin", .{ .name = .{ .bytes = "en-US" } });
    try emit(gpa, memorypack.TypeName, "type_name.bin", .{
        .name = .{ .bytes = "System.String, System.Private.CoreLib" },
    });
}
