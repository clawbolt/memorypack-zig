const std = @import("std");
const memorypack = @import("memorypack");

const Request = struct {
    id: i32,
    command: memorypack.Str,
    args: []const memorypack.Str,
};

const Response = struct {
    id: i32,
    ok: bool,
    message: memorypack.Str,
};

const max_message_size = 1024 * 1024;

fn readExact(reader: *std.Io.net.Stream.Reader, buffer: []u8) !void {
    try reader.interface.readSliceAll(buffer);
}

fn writeFrame(writer: *std.Io.net.Stream.Writer, allocator: std.mem.Allocator, value: anytype) !void {
    const payload = try memorypack.encode(allocator, value);
    defer allocator.free(payload);
    if (payload.len > std.math.maxInt(u32)) return error.MessageTooLarge;
    var length: [4]u8 = undefined;
    std.mem.writeInt(u32, &length, @intCast(payload.len), .little);
    try writer.interface.writeAll(&length);
    try writer.interface.writeAll(payload);
    try writer.interface.flush();
}

fn readFrame(
    reader: *std.Io.net.Stream.Reader,
    allocator: std.mem.Allocator,
    comptime T: type,
) !T {
    var length_bytes: [4]u8 = undefined;
    try readExact(reader, &length_bytes);
    const length = std.mem.readInt(u32, &length_bytes, .little);
    if (length > max_message_size) return error.MessageTooLarge;
    const payload = try allocator.alloc(u8, length);
    defer allocator.free(payload);
    try readExact(reader, payload);
    return memorypack.decode(T, allocator, payload);
}

fn sendRequest(
    writer: *std.Io.net.Stream.Writer,
    reader: *std.Io.net.Stream.Reader,
    allocator: std.mem.Allocator,
    id: i32,
    command: []const u8,
    args: []const []const u8,
) !Response {
    const request_args = try allocator.alloc(memorypack.Str, args.len);
    defer allocator.free(request_args);
    for (request_args, args) |*destination, source| destination.* = .{ .bytes = source };
    const request = Request{
        .id = id,
        .command = .{ .bytes = command },
        .args = request_args,
    };
    try writeFrame(writer, allocator, request);
    return readFrame(reader, allocator, Response);
}

fn expectResponse(response: *Response, allocator: std.mem.Allocator, id: i32, ok: bool, message: []const u8) !void {
    defer memorypack.deinit(Response, allocator, response);
    std.debug.print("  response id={d}, ok={any}, message={s}\n", .{
        response.id,
        response.ok,
        response.message.bytes,
    });
    std.debug.assert(response.id == id);
    std.debug.assert(response.ok == ok);
    std.debug.assert(std.mem.eql(u8, response.message.bytes, message));
}

pub fn main(init: std.process.Init) !void {
    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.next() orelse return error.InvalidData;
    const port_text = args.next() orelse "39123";
    if (args.next() != null) return error.InvalidData;
    const port = try std.fmt.parseInt(u16, port_text, 10);
    const allocator = std.heap.page_allocator;
    const address: std.Io.net.IpAddress = .{ .ip4 = .loopback(port) };
    var stream = try address.connect(init.io, .{ .mode = .stream });
    defer stream.close(init.io);
    var read_buffer: [4096]u8 = undefined;
    var write_buffer: [4096]u8 = undefined;
    var reader = stream.reader(init.io, &read_buffer);
    var writer = stream.writer(init.io, &write_buffer);

    std.debug.print("=== Zig RPC client connected to 127.0.0.1:{d} ===\n", .{port});

    std.debug.print("request id=1 command=ping\n", .{});
    var response = try sendRequest(&writer, &reader, allocator, 1, "ping", &.{});
    try expectResponse(&response, allocator, 1, true, "pong");

    std.debug.print("request id=2 command=echo args=[hello, world]\n", .{});
    response = try sendRequest(&writer, &reader, allocator, 2, "echo", &.{ "hello", "world" });
    try expectResponse(&response, allocator, 2, true, "hello world");

    std.debug.print("request id=3 command=add args=[7, 35]\n", .{});
    response = try sendRequest(&writer, &reader, allocator, 3, "add", &.{ "7", "35" });
    try expectResponse(&response, allocator, 3, true, "42");

    std.debug.print("request id=4 command=unknown\n", .{});
    response = try sendRequest(&writer, &reader, allocator, 4, "unknown", &.{});
    try expectResponse(&response, allocator, 4, false, "unknown command");

    std.debug.print("request id=5 command=shutdown\n", .{});
    response = try sendRequest(&writer, &reader, allocator, 5, "shutdown", &.{});
    try expectResponse(&response, allocator, 5, true, "bye");

    std.debug.print("RPC assertions: passed\n", .{});
}
