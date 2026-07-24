const std = @import("std");
const zdb = @import("zdb");
const memorypack = @import("memorypack");

const RpcKind = enum(u8) {
    ping = 0,
    put = 1,
    get = 2,
    delete = 3,
    query_status = 4,
    compact = 5,
    shutdown = 6,
};

const RpcRequest = struct {
    kind: RpcKind,
    id: i32,
    name: memorypack.Str,
    status: zdb.Status,
    score: i64,
    due: ?i32,
    tags: []const memorypack.Str,
    limit: i32,
    offset: i32,
};

const RpcResponse = struct {
    ok: bool,
    id: i32,
    count: i32,
    message: memorypack.Str,
};

const max_rpc_frame = 1024 * 1024;

fn writeFrame(
    writer: *std.Io.net.Stream.Writer,
    allocator: std.mem.Allocator,
    value: anytype,
) !void {
    const payload = try memorypack.encode(allocator, value);
    defer allocator.free(payload);
    if (payload.len > max_rpc_frame) return error.FrameTooLarge;
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
    try reader.interface.readSliceAll(&length_bytes);
    const length = std.mem.readInt(u32, &length_bytes, .little);
    if (length > max_rpc_frame) return error.FrameTooLarge;
    const payload = try allocator.alloc(u8, length);
    defer allocator.free(payload);
    try reader.interface.readSliceAll(payload);
    return memorypack.decode(T, allocator, payload);
}

fn parseStatus(value: []const u8) !zdb.Status {
    if (std.mem.eql(u8, value, "draft")) return .draft;
    if (std.mem.eql(u8, value, "active")) return .active;
    if (std.mem.eql(u8, value, "archived")) return .archived;
    return error.InvalidStatus;
}

fn parseId(value: []const u8) !i32 {
    return std.fmt.parseInt(i32, value, 10);
}

fn printDocument(document: zdb.Document) void {
    std.debug.print("#{d} [{s}] {s} score={d}", .{
        document.id,
        @tagName(document.status),
        document.name.bytes,
        document.score,
    });
    if (document.due) |due| std.debug.print(" due={d}", .{due});
    if (document.tags.len > 0) {
        std.debug.print(" tags=", .{});
        for (document.tags, 0..) |tag, index| {
            if (index > 0) std.debug.print(",", .{});
            std.debug.print("{s}", .{tag.bytes});
        }
    }
    std.debug.print("\n", .{});
}

fn printStore(store: *zdb.Store, allocator: std.mem.Allocator) !void {
    var ids: std.ArrayList(i32) = .empty;
    defer ids.deinit(allocator);
    var iterator = store.documents.valueIterator();
    while (iterator.next()) |document| try ids.append(allocator, document.id);
    for (ids.items, 0..) |*id, index| {
        for (ids.items[index + 1 ..]) |*other| {
            if (other.* < id.*) std.mem.swap(i32, id, other);
        }
    }
    for (ids.items) |id| printDocument(store.get(id).?);
}

fn hasTag(document: zdb.Document, wanted: []const u8) bool {
    for (document.tags) |tag| {
        if (std.mem.eql(u8, tag.bytes, wanted)) return true;
    }
    return false;
}

fn put(
    store: *zdb.Store,
    allocator: std.mem.Allocator,
    args: *std.process.Args.Iterator,
) !void {
    const id = try parseId(args.next() orelse return error.MissingId);
    const name = args.next() orelse return error.MissingName;
    var status: zdb.Status = .active;
    var score: i64 = 0;
    var due: ?i32 = null;
    var tags: std.ArrayList(memorypack.Str) = .empty;
    defer tags.deinit(allocator);
    while (args.next()) |option| {
        if (std.mem.eql(u8, option, "--status")) {
            status = try parseStatus(args.next() orelse return error.MissingStatus);
        } else if (std.mem.eql(u8, option, "--score")) {
            score = try std.fmt.parseInt(i64, args.next() orelse return error.MissingScore, 10);
        } else if (std.mem.eql(u8, option, "--due")) {
            due = try parseId(args.next() orelse return error.MissingDue);
        } else if (std.mem.eql(u8, option, "--tags")) {
            var parts = std.mem.splitScalar(u8, args.next() orelse return error.MissingTags, ',');
            while (parts.next()) |part| {
                if (part.len == 0) continue;
                try tags.append(allocator, .{ .bytes = part });
            }
        } else {
            return error.UnknownOption;
        }
    }
    try store.put(.{
        .id = id,
        .name = .{ .bytes = name },
        .status = status,
        .score = score,
        .due = due,
        .tags = tags.items,
    });
    std.debug.print("put #{d}\n", .{id});
}

fn query(store: *zdb.Store, allocator: std.mem.Allocator, args: *std.process.Args.Iterator) !void {
    var status: ?zdb.Status = null;
    var tag: ?[]const u8 = null;
    var limit: usize = 100;
    var offset: usize = 0;
    while (args.next()) |option| {
        if (std.mem.eql(u8, option, "--status")) {
            status = try parseStatus(args.next() orelse return error.MissingStatus);
        } else if (std.mem.eql(u8, option, "--tag")) {
            tag = args.next() orelse return error.MissingTag;
        } else if (std.mem.eql(u8, option, "--limit")) {
            limit = try std.fmt.parseInt(usize, args.next() orelse return error.MissingLimit, 10);
        } else if (std.mem.eql(u8, option, "--offset")) {
            offset = try std.fmt.parseInt(usize, args.next() orelse return error.MissingOffset, 10);
        } else {
            return error.UnknownOption;
        }
    }
    if (status) |wanted| {
        const ids = try store.queryStatusPage(allocator, wanted, offset, limit);
        defer allocator.free(ids);
        std.debug.print("query status={s} (secondary index)\n", .{@tagName(wanted)});
        for (ids) |id| printDocument(store.get(id).?);
    } else if (tag) |wanted| {
        std.debug.print("query tag={s}\n", .{wanted});
        var skipped: usize = 0;
        var emitted: usize = 0;
        var iterator = store.documents.valueIterator();
        while (iterator.next()) |document| {
            if (hasTag(document.*, wanted)) {
                if (skipped < offset) {
                    skipped += 1;
                    continue;
                }
                if (emitted >= limit) break;
                printDocument(document.*);
                emitted += 1;
            }
        }
    } else {
        return error.MissingQuery;
    }
}

fn parsePort(value: []const u8) !u16 {
    return std.fmt.parseInt(u16, value, 10);
}

fn listWithPagination(store: *zdb.Store, allocator: std.mem.Allocator, args: *std.process.Args.Iterator) !void {
    var limit: usize = 100;
    var offset: usize = 0;
    while (args.next()) |option| {
        if (std.mem.eql(u8, option, "--limit")) {
            limit = try std.fmt.parseInt(usize, args.next() orelse return error.MissingLimit, 10);
        } else if (std.mem.eql(u8, option, "--offset")) {
            offset = try std.fmt.parseInt(usize, args.next() orelse return error.MissingOffset, 10);
        } else return error.UnknownOption;
    }
    const ids = try store.listIds(allocator, offset, limit);
    defer allocator.free(ids);
    for (ids) |id| printDocument(store.get(id).?);
}

fn response(ok: bool, id: i32, count: i32, message: []const u8) RpcResponse {
    return .{
        .ok = ok,
        .id = id,
        .count = count,
        .message = .{ .bytes = message },
    };
}

fn handleRpc(store: *zdb.Store, allocator: std.mem.Allocator, request: RpcRequest) !RpcResponse {
    switch (request.kind) {
        .ping => return response(true, request.id, 0, "pong"),
        .put => {
            try store.put(.{
                .id = request.id,
                .name = request.name,
                .status = request.status,
                .score = request.score,
                .due = request.due,
                .tags = request.tags,
            });
            return response(true, request.id, 1, "put");
        },
        .get => {
            if (store.get(request.id) != null) return response(true, request.id, 1, "found");
            return response(false, request.id, 0, "not found");
        },
        .delete => {
            try store.delete(request.id);
            return response(true, request.id, 1, "deleted");
        },
        .query_status => {
            var ids: std.ArrayList(i32) = .empty;
            defer ids.deinit(allocator);
            try store.queryStatus(request.status, &ids);
            const offset: usize = if (request.offset < 0) return error.InvalidOffset else @intCast(request.offset);
            const limit: usize = if (request.limit < 0) return error.InvalidLimit else @intCast(request.limit);
            const start = @min(offset, ids.items.len);
            const end = @min(start +| limit, ids.items.len);
            return response(true, request.id, @intCast(end - start), "query");
        },
        .compact => {
            try store.compact();
            return response(true, request.id, 0, "compacted");
        },
        .shutdown => return response(true, request.id, 0, "bye"),
    }
}

fn serve(init: std.process.Init, allocator: std.mem.Allocator, directory: []const u8, port: u16) !void {
    var store = try zdb.Store.open(init.io, allocator, directory);
    defer store.deinit();
    const address: std.Io.net.IpAddress = .{ .ip4 = .loopback(port) };
    var server = try address.listen(init.io, .{ .reuse_address = true });
    defer server.deinit(init.io);
    std.debug.print("zdb server listening on 127.0.0.1:{d}\n", .{port});
    var stream = try server.accept(init.io);
    defer stream.close(init.io);
    var read_buffer: [4096]u8 = undefined;
    var write_buffer: [4096]u8 = undefined;
    var reader = stream.reader(init.io, &read_buffer);
    var writer = stream.writer(init.io, &write_buffer);
    while (true) {
        var request = readFrame(&reader, allocator, RpcRequest) catch |err| switch (err) {
            error.EndOfStream => return,
            else => return err,
        };
        defer memorypack.deinit(RpcRequest, allocator, &request);
        const reply = handleRpc(&store, allocator, request) catch |err| response(false, request.id, 0, @errorName(err));
        try writeFrame(&writer, allocator, reply);
        if (request.kind == .shutdown) break;
    }
}

fn client(init: std.process.Init, allocator: std.mem.Allocator, port: u16) !void {
    const address: std.Io.net.IpAddress = .{ .ip4 = .loopback(port) };
    var stream = try address.connect(init.io, .{ .mode = .stream });
    defer stream.close(init.io);
    var read_buffer: [4096]u8 = undefined;
    var write_buffer: [4096]u8 = undefined;
    var reader = stream.reader(init.io, &read_buffer);
    var writer = stream.writer(init.io, &write_buffer);
    const send = struct {
        fn call(
            init_io: std.Io,
            allocator_: std.mem.Allocator,
            writer_: *std.Io.net.Stream.Writer,
            reader_: *std.Io.net.Stream.Reader,
            request: RpcRequest,
        ) !RpcResponse {
            try writeFrame(writer_, allocator_, request);
            _ = init_io;
            return readFrame(reader_, allocator_, RpcResponse);
        }
    }.call;
    const blank_tags: []const memorypack.Str = &.{};
    const requests = [_]RpcRequest{
        .{ .kind = .ping, .id = 1, .name = .{ .bytes = "" }, .status = .active, .score = 0, .due = null, .tags = blank_tags, .limit = 0, .offset = 0 },
        .{ .kind = .put, .id = 7, .name = .{ .bytes = "Networked" }, .status = .active, .score = 77, .due = null, .tags = blank_tags, .limit = 0, .offset = 0 },
        .{ .kind = .get, .id = 7, .name = .{ .bytes = "" }, .status = .active, .score = 0, .due = null, .tags = blank_tags, .limit = 0, .offset = 0 },
        .{ .kind = .query_status, .id = 4, .name = .{ .bytes = "" }, .status = .active, .score = 0, .due = null, .tags = blank_tags, .limit = 10, .offset = 0 },
        .{ .kind = .compact, .id = 5, .name = .{ .bytes = "" }, .status = .active, .score = 0, .due = null, .tags = blank_tags, .limit = 0, .offset = 0 },
        .{ .kind = .shutdown, .id = 6, .name = .{ .bytes = "" }, .status = .active, .score = 0, .due = null, .tags = blank_tags, .limit = 0, .offset = 0 },
    };
    for (requests) |request| {
        var reply = try send(init.io, allocator, &writer, &reader, request);
        defer memorypack.deinit(RpcResponse, allocator, &reply);
        std.debug.print("rpc {s}: ok={any} message={s} count={d}\n", .{
            @tagName(request.kind),
            reply.ok,
            reply.message.bytes,
            reply.count,
        });
        if (!reply.ok) return error.RpcRequestFailed;
        if (request.kind == .ping and !std.mem.eql(u8, reply.message.bytes, "pong")) return error.BadRpcReply;
        if (request.kind == .get and reply.count != 1) return error.BadRpcReply;
    }
    std.debug.print("server round-trip assertions: passed\n", .{});
}

pub fn main(init: std.process.Init) !void {
    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.next() orelse return error.InvalidData;
    const directory = args.next() orelse ".zdb";
    const command = args.next() orelse return error.MissingCommand;
    const allocator = std.heap.page_allocator;
    if (std.mem.eql(u8, command, "serve") or std.mem.eql(u8, command, "client")) {
        const port_option = args.next() orelse return error.MissingPort;
        if (!std.mem.eql(u8, port_option, "--port")) return error.UnknownOption;
        const port = try parsePort(args.next() orelse return error.MissingPort);
        if (args.next() != null) return error.UnknownOption;
        if (std.mem.eql(u8, command, "serve")) {
            try serve(init, allocator, directory, port);
        } else {
            try client(init, allocator, port);
        }
        return;
    }
    var store = try zdb.Store.open(init.io, allocator, directory);
    defer store.deinit();

    if (std.mem.eql(u8, command, "put")) {
        try put(&store, allocator, &args);
    } else if (std.mem.eql(u8, command, "get")) {
        const id = try parseId(args.next() orelse return error.MissingId);
        if (args.next() != null) return error.UnknownOption;
        if (store.get(id)) |document| printDocument(document);
    } else if (std.mem.eql(u8, command, "delete")) {
        const id = try parseId(args.next() orelse return error.MissingId);
        if (args.next() != null) return error.UnknownOption;
        try store.delete(id);
        std.debug.print("deleted #{d}\n", .{id});
    } else if (std.mem.eql(u8, command, "query")) {
        try query(&store, allocator, &args);
    } else if (std.mem.eql(u8, command, "list")) {
        try listWithPagination(&store, allocator, &args);
    } else if (std.mem.eql(u8, command, "compact")) {
        if (args.next() != null) return error.UnknownOption;
        try store.compact();
        std.debug.print("compacted snapshot_version={d}, wal_frames={d}\n", .{
            store.snapshot_version,
            store.wal_frames,
        });
    } else if (std.mem.eql(u8, command, "stats")) {
        if (args.next() != null) return error.UnknownOption;
        std.debug.print("documents={d}, snapshot_version={d}, wal_frames={d}\n", .{
            store.count(),
            store.snapshot_version,
            store.wal_frames,
        });
    } else {
        return error.UnknownCommand;
    }
}
