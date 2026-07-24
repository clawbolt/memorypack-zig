const std = @import("std");
const memorypack = @import("memorypack");
const audit = @import("audit");

const Empty = struct {};

const RequestKind = enum(u8) {
    append = 0,
    query = 1,
    verify = 2,
    stats = 3,
    ping = 4,
    shutdown = 5,
};

const AppendRequest = struct {
    actor: memorypack.Str,
    action: memorypack.Str,
    resource: memorypack.Str,
    detail: memorypack.Str,
};

const QueryRequest = struct {
    actor: ?memorypack.Str,
    action: ?memorypack.Str,
    start_seq: ?i64,
    end_seq: ?i64,
    offset: i32,
    limit: i32,
};

const Request = union(RequestKind) {
    append: AppendRequest,
    query: QueryRequest,
    verify: Empty,
    stats: Empty,
    ping: Empty,
    shutdown: Empty,
};

const Response = struct {
    ok: bool,
    message: memorypack.Str,
    message_owned: bool,
    seq: i64,
    entries: []const audit.Entry,
    intact: bool,
    broken_seq: i64,
    entry_count: i64,
    next_seq: i64,
    tip_hash: [32]u8,
};

const max_frame_size = 1024 * 1024;

fn writeFrame(writer: *std.Io.net.Stream.Writer, allocator: std.mem.Allocator, value: anytype) !void {
    const payload = try memorypack.encode(allocator, value);
    defer allocator.free(payload);
    if (payload.len > max_frame_size) return error.FrameTooLarge;
    var header: [4]u8 = undefined;
    std.mem.writeInt(u32, &header, @intCast(payload.len), .little);
    try writer.interface.writeAll(&header);
    try writer.interface.writeAll(payload);
    try writer.interface.flush();
}

fn readFrame(reader: *std.Io.net.Stream.Reader, allocator: std.mem.Allocator, comptime T: type) !T {
    var header: [4]u8 = undefined;
    try reader.interface.readSliceAll(&header);
    const length = std.mem.readInt(u32, &header, .little);
    if (length > max_frame_size) return error.FrameTooLarge;
    const payload = try allocator.alloc(u8, length);
    defer allocator.free(payload);
    try reader.interface.readSliceAll(payload);
    return memorypack.decode(T, allocator, payload);
}

fn emptyResponse(ok: bool, message: []const u8) Response {
    return .{
        .ok = ok,
        .message = .{ .bytes = message },
        .message_owned = false,
        .seq = -1,
        .entries = &.{},
        .intact = false,
        .broken_seq = -1,
        .entry_count = 0,
        .next_seq = 0,
        .tip_hash = [_]u8{0} ** 32,
    };
}

fn handleRequest(store: *audit.Store, allocator: std.mem.Allocator, request: Request) !Response {
    switch (request) {
        .append => |value| {
            const seq = try store.append(.{
                .actor = value.actor,
                .action = value.action,
                .resource = value.resource,
                .detail = value.detail,
            });
            var response = emptyResponse(true, "appended");
            response.seq = seq;
            return response;
        },
        .query => |value| {
            if (value.offset < 0 or value.limit <= 0) return error.InvalidInput;
            const entries = try store.query(.{
                .actor = if (value.actor) |actor| actor.bytes else null,
                .action = if (value.action) |action| action.bytes else null,
                .start_seq = value.start_seq,
                .end_seq = value.end_seq,
                .offset = @intCast(value.offset),
                .limit = @intCast(value.limit),
            });
            var response = emptyResponse(true, "query");
            response.entries = entries;
            return response;
        },
        .verify => {
            const result = try store.verify();
            var response = emptyResponse(result.intact, result.reason.bytes);
            response.intact = result.intact;
            response.broken_seq = result.broken_seq;
            response.entry_count = @intCast(result.entries);
            response.message = .{ .bytes = try allocator.dupe(u8, result.reason.bytes) };
            response.message_owned = true;
            allocator.free(result.reason.bytes);
            return response;
        },
        .stats => {
            const stats = try store.stats();
            var response = emptyResponse(true, "stats");
            response.entry_count = @intCast(stats.entries);
            response.next_seq = stats.next_seq;
            response.tip_hash = stats.tip_hash;
            return response;
        },
        .ping => return emptyResponse(true, "pong"),
        .shutdown => return emptyResponse(true, "bye"),
    }
}

fn freeServerResponse(allocator: std.mem.Allocator, response: *Response) void {
    if (response.message_owned) allocator.free(response.message.bytes);
    if (response.entries.len > 0) {
        for (response.entries) |*entry| {
            allocator.free(entry.actor.bytes);
            allocator.free(entry.action.bytes);
            allocator.free(entry.resource.bytes);
            allocator.free(entry.detail.bytes);
        }
        allocator.free(response.entries);
    }
}

fn freeClientResponse(allocator: std.mem.Allocator, response: *Response) void {
    memorypack.deinit(Response, allocator, response);
}

fn serve(init: std.process.Init, allocator: std.mem.Allocator, directory: []const u8, port: u16) !void {
    var store = try audit.Store.open(init.io, allocator, .{ .data_dir = directory });
    defer store.deinit();
    const address: std.Io.net.IpAddress = .{ .ip4 = .loopback(port) };
    var server = try address.listen(init.io, .{ .reuse_address = true });
    defer server.deinit(init.io);
    std.debug.print("audit server listening on 127.0.0.1:{d}\n", .{port});
    var stopping = false;
    while (!stopping) {
        var stream = try server.accept(init.io);
        defer stream.close(init.io);
        var read_buffer: [4096]u8 = undefined;
        var write_buffer: [4096]u8 = undefined;
        var reader = stream.reader(init.io, &read_buffer);
        var writer = stream.writer(init.io, &write_buffer);
        while (true) {
            var request = readFrame(&reader, allocator, Request) catch |err| switch (err) {
                error.EndOfStream => break,
                else => return err,
            };
            defer memorypack.deinit(Request, allocator, &request);
            std.debug.print("audit request kind={s}\n", .{@tagName(std.meta.activeTag(request))});
            var response = handleRequest(&store, allocator, request) catch |err| emptyResponse(false, @errorName(err));
            const shutdown = request == .shutdown;
            defer freeServerResponse(allocator, &response);
            try writeFrame(&writer, allocator, response);
            if (shutdown) {
                stopping = true;
                break;
            }
        }
    }
}

const Client = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    stream: std.Io.net.Stream,
    reader: std.Io.net.Stream.Reader,
    writer: std.Io.net.Stream.Writer,

    fn connect(init: std.process.Init, allocator: std.mem.Allocator, port: u16) !Client {
        const address: std.Io.net.IpAddress = .{ .ip4 = .loopback(port) };
        var stream = try address.connect(init.io, .{ .mode = .stream });
        const read_buffer = try allocator.alloc(u8, 4096);
        errdefer allocator.free(read_buffer);
        const write_buffer = try allocator.alloc(u8, 4096);
        errdefer allocator.free(write_buffer);
        return .{
            .allocator = allocator,
            .io = init.io,
            .stream = stream,
            .reader = stream.reader(init.io, read_buffer),
            .writer = stream.writer(init.io, write_buffer),
        };
    }

    fn deinit(self: *Client) void {
        self.stream.close(self.io);
        self.allocator.free(self.reader.interface.buffer);
        self.allocator.free(self.writer.interface.buffer);
    }

    fn call(self: *Client, request: Request) !Response {
        try writeFrame(&self.writer, self.allocator, request);
        return readFrame(&self.reader, self.allocator, Response);
    }
};

fn parsePort(args: *std.process.Args.Iterator) !u16 {
    const flag = args.next() orelse return error.MissingPort;
    if (!std.mem.eql(u8, flag, "--port")) return error.UnknownOption;
    return std.fmt.parseInt(u16, args.next() orelse return error.MissingPort, 10);
}

fn requiredOption(args: *std.process.Args.Iterator, expected: []const u8) ![]const u8 {
    const flag = args.next() orelse return error.MissingOption;
    if (!std.mem.eql(u8, flag, expected)) return error.UnknownOption;
    return args.next() orelse return error.MissingOption;
}

fn clientCommand(init: std.process.Init, allocator: std.mem.Allocator, command: []const u8, args: *std.process.Args.Iterator) !void {
    var client = try Client.connect(init, allocator, try parsePort(args));
    defer client.deinit();
    var request: Request = undefined;
    if (std.mem.eql(u8, command, "log")) {
        const actor = try requiredOption(args, "--actor");
        const action = try requiredOption(args, "--action");
        const resource = try requiredOption(args, "--resource");
        const detail = try requiredOption(args, "--detail");
        request = .{ .append = .{ .actor = .{ .bytes = actor }, .action = .{ .bytes = action }, .resource = .{ .bytes = resource }, .detail = .{ .bytes = detail } } };
    } else if (std.mem.eql(u8, command, "query")) {
        var actor: ?memorypack.Str = null;
        var action: ?memorypack.Str = null;
        var start_seq: ?i64 = null;
        var end_seq: ?i64 = null;
        var offset: i32 = 0;
        var limit: i32 = 100;
        while (args.next()) |flag| {
            if (std.mem.eql(u8, flag, "--actor")) {
                actor = .{ .bytes = args.next() orelse return error.MissingOption };
            } else if (std.mem.eql(u8, flag, "--action")) {
                action = .{ .bytes = args.next() orelse return error.MissingOption };
            } else if (std.mem.eql(u8, flag, "--start")) {
                start_seq = try std.fmt.parseInt(i64, args.next() orelse return error.MissingOption, 10);
            } else if (std.mem.eql(u8, flag, "--end")) {
                end_seq = try std.fmt.parseInt(i64, args.next() orelse return error.MissingOption, 10);
            } else if (std.mem.eql(u8, flag, "--offset")) {
                offset = try std.fmt.parseInt(i32, args.next() orelse return error.MissingOption, 10);
            } else if (std.mem.eql(u8, flag, "--limit")) {
                limit = try std.fmt.parseInt(i32, args.next() orelse return error.MissingOption, 10);
            } else return error.UnknownOption;
        }
        request = .{ .query = .{ .actor = actor, .action = action, .start_seq = start_seq, .end_seq = end_seq, .offset = offset, .limit = limit } };
    } else if (std.mem.eql(u8, command, "verify")) {
        if (args.next() != null) return error.UnknownOption;
        request = .{ .verify = .{} };
    } else if (std.mem.eql(u8, command, "stats")) {
        if (args.next() != null) return error.UnknownOption;
        request = .{ .stats = .{} };
    } else if (std.mem.eql(u8, command, "ping")) {
        if (args.next() != null) return error.UnknownOption;
        request = .{ .ping = .{} };
    } else if (std.mem.eql(u8, command, "shutdown")) {
        if (args.next() != null) return error.UnknownOption;
        request = .{ .shutdown = .{} };
    } else return error.UnknownCommand;
    var response = try client.call(request);
    defer freeClientResponse(allocator, &response);
    if (!response.ok and !std.mem.eql(u8, command, "verify")) return error.RequestFailed;
    if (std.mem.eql(u8, command, "log")) {
        std.debug.print("log: seq={d}\n", .{response.seq});
    } else if (std.mem.eql(u8, command, "query")) {
        std.debug.print("query: count={d}\n", .{response.entries.len});
        for (response.entries) |entry| std.debug.print("  seq={d} actor={s} action={s} resource={s} detail={s}\n", .{ entry.seq, entry.actor.bytes, entry.action.bytes, entry.resource.bytes, entry.detail.bytes });
    } else if (std.mem.eql(u8, command, "verify")) {
        if (response.intact) {
            std.debug.print("verify: chain intact, {d} entries\n", .{response.entry_count});
        } else {
            std.debug.print("verify: TAMPERING DETECTED at seq {d}: {s}\n", .{ response.broken_seq, response.message.bytes });
        }
    } else if (std.mem.eql(u8, command, "stats")) {
        std.debug.print("stats: entries={d} next_seq={d}\n", .{ response.entry_count, response.next_seq });
    } else {
        std.debug.print("{s}: {s}\n", .{ command, response.message.bytes });
    }
}

pub fn main(init: std.process.Init) !void {
    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.next() orelse return error.InvalidData;
    const command = args.next() orelse return error.MissingCommand;
    const allocator = std.heap.page_allocator;
    if (std.mem.eql(u8, command, "serve")) {
        const directory = args.next() orelse return error.MissingDirectory;
        const port = try parsePort(&args);
        if (args.next() != null) return error.UnknownOption;
        return serve(init, allocator, directory, port);
    }
    return clientCommand(init, allocator, command, &args);
}
