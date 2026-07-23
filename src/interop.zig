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
}
