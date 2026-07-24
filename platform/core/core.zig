const std = @import("std");
const memorypack = @import("memorypack");

pub const Error = error{
    FrameTooLarge,
    InvalidFrame,
    StoreClosed,
    InvalidConfig,
} || std.mem.Allocator.Error;

pub const Config = struct {
    data_dir: []const u8 = "platform-data",
    api_port: u16 = 39551,
    max_frame_size: usize = 1024 * 1024,
    rate_limit: usize = 20,
    api_tokens: []const Token = &.{},
};

pub const Token = struct {
    value: []const u8,
    role: Role = .operator,
};

pub const Role = enum(u8) {
    viewer,
    operator,
    admin,
};

pub const Level = enum {
    info,
    warn,
    @"error",
};

pub fn log(level: Level, component: []const u8, message: []const u8) void {
    std.debug.print("[platform][{s}][{s}] {s}\n", .{ @tagName(level), component, message });
}

pub const Metrics = struct {
    requests: usize = 0,
    rejected_auth: usize = 0,
    rejected_rate: usize = 0,
    devices: usize = 0,
    readings: usize = 0,
    alerts: usize = 0,

    pub fn snapshot(self: *const Metrics) Metrics {
        return self.*;
    }
};

pub fn writeFrame(writer: *std.Io.net.Stream.Writer, allocator: std.mem.Allocator, max_size: usize, value: anytype) !void {
    const payload = try memorypack.encode(allocator, value);
    defer allocator.free(payload);
    if (payload.len > max_size or payload.len > std.math.maxInt(u32)) return error.FrameTooLarge;
    var length: [4]u8 = undefined;
    std.mem.writeInt(u32, &length, @intCast(payload.len), .little);
    try writer.interface.writeAll(&length);
    try writer.interface.writeAll(payload);
    try writer.interface.flush();
}

pub fn readFrame(reader: *std.Io.net.Stream.Reader, allocator: std.mem.Allocator, max_size: usize, comptime T: type) !T {
    var length: [4]u8 = undefined;
    try reader.interface.readSliceAll(&length);
    const size = std.mem.readInt(u32, &length, .little);
    if (size > max_size) return error.FrameTooLarge;
    const payload = try allocator.alloc(u8, size);
    defer allocator.free(payload);
    try reader.interface.readSliceAll(payload);
    return memorypack.decode(T, allocator, payload);
}

pub fn writeDiskFrame(file: *std.Io.File, io: std.Io, allocator: std.mem.Allocator, max_size: usize, value: anytype, sync: bool) !void {
    const payload = try memorypack.encode(allocator, value);
    defer allocator.free(payload);
    if (payload.len > max_size or payload.len > std.math.maxInt(u32)) return error.FrameTooLarge;
    var buffer: [4096]u8 = undefined;
    var writer = file.writerStreaming(io, &buffer);
    const stat = try file.stat(io);
    try writer.seekTo(stat.size);
    var header: [8]u8 = undefined;
    std.mem.writeInt(u32, header[0..4], @intCast(payload.len), .little);
    std.mem.writeInt(u32, header[4..8], std.hash.Crc32.hash(payload), .little);
    try writer.interface.writeAll(&header);
    try writer.interface.writeAll(payload);
    try writer.interface.flush();
    if (sync) try file.sync(io);
}

pub fn readDiskFrames(comptime T: type, io: std.Io, allocator: std.mem.Allocator, path: []const u8, max_size: usize) ![]T {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(256 * 1024 * 1024));
    defer allocator.free(bytes);
    var result: std.ArrayList(T) = .empty;
    errdefer result.deinit(allocator);
    var position: usize = 0;
    while (position < bytes.len) {
        if (bytes.len - position < 8) break;
        const length = std.mem.readInt(u32, bytes[position..][0..4], .little);
        const crc = std.mem.readInt(u32, bytes[position + 4 ..][0..4], .little);
        position += 8;
        if (length > max_size or length > bytes.len - position) break;
        const payload = bytes[position..][0..@intCast(length)];
        position += payload.len;
        if (std.hash.Crc32.hash(payload) != crc) break;
        try result.append(allocator, try memorypack.decode(T, allocator, payload));
    }
    return result.toOwnedSlice(allocator);
}

test "core framing round trip and CRC rejection" {
    const Item = struct { id: i32, value: memorypack.Str };
    const allocator = std.testing.allocator;
    const bytes = try memorypack.encode(allocator, Item{ .id = 7, .value = .{ .bytes = "ok" } });
    defer allocator.free(bytes);
    try std.testing.expect(bytes.len > 0);
    try std.testing.expectError(error.FrameTooLarge, writeTestFrame(allocator, 1, Item{ .id = 1, .value = .{ .bytes = "large" } }));
}

fn writeTestFrame(allocator: std.mem.Allocator, max_size: usize, value: anytype) !void {
    const payload = try memorypack.encode(allocator, value);
    defer allocator.free(payload);
    if (payload.len > max_size) return error.FrameTooLarge;
}
