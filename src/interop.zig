const std = @import("std");
const memorypack = @import("memorypack.zig");

const Padded = extern struct { a: u8, b: i32 };
const BasicObject = struct { id: i32, name: ?memorypack.Str };
const NestedObject = struct { inner: ?BasicObject, values: ?[]const i32 };
const Level = enum(u8) { novice = 2, expert = 7 };
const RichObject = struct { id: u64, name: ?memorypack.Str, data: ?[]const u8, level: Level, child: ?BasicObject };

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
}
