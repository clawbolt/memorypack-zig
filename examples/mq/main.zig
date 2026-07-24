const std = @import("std");
const memorypack = @import("memorypack");
const mq = @import("mq");

const Empty = struct {};

const RequestKind = enum(u8) {
    produce = 0,
    fetch = 1,
    commit = 2,
    create_topic = 3,
    list_topics = 4,
    ping = 5,
    stats = 6,
    shutdown = 7,
};

const ProduceRequest = struct {
    topic: memorypack.Str,
    key: memorypack.Str,
    value: memorypack.Str,
    headers: []const memorypack.Str,
};

const FetchRequest = struct {
    topic: memorypack.Str,
    group: memorypack.Str,
    max: i32,
};

const CommitRequest = struct {
    topic: memorypack.Str,
    group: memorypack.Str,
    offset: i64,
};

const TopicRequest = struct {
    topic: memorypack.Str,
};

const Request = union(RequestKind) {
    produce: ProduceRequest,
    fetch: FetchRequest,
    commit: CommitRequest,
    create_topic: TopicRequest,
    list_topics: Empty,
    ping: Empty,
    stats: Empty,
    shutdown: Empty,
};

const Response = struct {
    ok: bool,
    message: memorypack.Str,
    offset: i64,
    messages: []const mq.Message,
    topics: []const memorypack.Str,
    topic_count: i32,
    message_count: i64,
    group_count: i32,
};

const max_frame_size = 1024 * 1024;

fn writeFrame(writer: *std.Io.net.Stream.Writer, allocator: std.mem.Allocator, value: anytype) !void {
    const payload = try memorypack.encode(allocator, value);
    defer allocator.free(payload);
    if (payload.len > max_frame_size) return error.FrameTooLarge;
    var length: [4]u8 = undefined;
    std.mem.writeInt(u32, &length, @intCast(payload.len), .little);
    try writer.interface.writeAll(&length);
    try writer.interface.writeAll(payload);
    try writer.interface.flush();
}

fn readFrame(reader: *std.Io.net.Stream.Reader, allocator: std.mem.Allocator, comptime T: type) !T {
    var length_bytes: [4]u8 = undefined;
    try reader.interface.readSliceAll(&length_bytes);
    const length = std.mem.readInt(u32, &length_bytes, .little);
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
        .offset = -1,
        .messages = &.{},
        .topics = &.{},
        .topic_count = 0,
        .message_count = 0,
        .group_count = 0,
    };
}

fn handleRequest(broker: *mq.Broker, allocator: std.mem.Allocator, request: Request) !Response {
    switch (request) {
        .produce => |value| {
            const offset = try broker.produce(.{
                .topic = value.topic,
                .key = value.key,
                .value = value.value,
                .headers = value.headers,
            });
            var result = emptyResponse(true, "produced");
            result.offset = offset;
            return result;
        },
        .fetch => |value| {
            if (value.max <= 0) return error.BatchTooLarge;
            const messages = try broker.fetch(value.topic.bytes, value.group.bytes, @intCast(value.max));
            var result = emptyResponse(true, "fetched");
            result.messages = messages;
            return result;
        },
        .commit => |value| {
            try broker.commit(value.group.bytes, value.topic.bytes, value.offset);
            return emptyResponse(true, "committed");
        },
        .create_topic => |value| {
            try broker.createTopic(value.topic.bytes);
            return emptyResponse(true, "topic created");
        },
        .list_topics => {
            const names = try broker.listTopics(allocator);
            var result = emptyResponse(true, "topics");
            const topic_payload = try allocator.alloc(memorypack.Str, names.len);
            for (topic_payload, names) |*destination, name| destination.* = .{ .bytes = name };
            result.topics = topic_payload;
            allocator.free(names);
            return result;
        },
        .ping => return emptyResponse(true, "pong"),
        .stats => {
            const stats = try broker.stats();
            var result = emptyResponse(true, "stats");
            result.topic_count = @intCast(stats.topics);
            result.message_count = @intCast(stats.messages);
            result.group_count = @intCast(stats.groups);
            return result;
        },
        .shutdown => return emptyResponse(true, "bye"),
    }
}

fn freeResponse(allocator: std.mem.Allocator, response: *Response) void {
    memorypack.deinit(Response, allocator, response);
}

fn freeServerResponse(allocator: std.mem.Allocator, response: *Response) void {
    if (response.messages.len > 0) {
        for (response.messages) |*message| memorypack.deinit(mq.Message, allocator, @constCast(message));
        allocator.free(response.messages);
    }
    if (response.topics.len > 0) allocator.free(response.topics);
}

fn serve(init: std.process.Init, allocator: std.mem.Allocator, directory: []const u8, port: u16) !void {
    var broker = try mq.Broker.open(init.io, allocator, .{ .data_dir = directory });
    defer broker.deinit();
    const address: std.Io.net.IpAddress = .{ .ip4 = .loopback(port) };
    var server = try address.listen(init.io, .{ .reuse_address = true });
    defer server.deinit(init.io);
    std.debug.print("mq server listening on 127.0.0.1:{d}\n", .{port});
    var stopping = false;
    while (!stopping) {
        var stream = server.accept(init.io) catch |err| return err;
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
            std.debug.print("mq request kind={s}\n", .{@tagName(std.meta.activeTag(request))});
            var response = handleRequest(&broker, allocator, request) catch |err| emptyResponse(false, @errorName(err));
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
    const option = args.next() orelse return error.MissingPort;
    if (!std.mem.eql(u8, option, "--port")) return error.UnknownOption;
    return std.fmt.parseInt(u16, args.next() orelse return error.MissingPort, 10);
}

fn clientCommand(init: std.process.Init, allocator: std.mem.Allocator, command: []const u8, args: *std.process.Args.Iterator) !void {
    var client = try Client.connect(init, allocator, try parsePort(args));
    defer client.deinit();
    const blank: []const memorypack.Str = &.{};
    var request: Request = undefined;
    if (std.mem.eql(u8, command, "create")) {
        const topic = args.next() orelse return error.MissingTopic;
        request = .{ .create_topic = .{ .topic = .{ .bytes = topic } } };
    } else if (std.mem.eql(u8, command, "produce")) {
        var topic: ?[]const u8 = null;
        var key: ?[]const u8 = null;
        var value: ?[]const u8 = null;
        while (args.next()) |option| {
            if (std.mem.eql(u8, option, "--topic")) {
                topic = args.next() orelse return error.MissingTopic;
            } else if (std.mem.eql(u8, option, "--key")) {
                key = args.next() orelse return error.MissingKey;
            } else if (std.mem.eql(u8, option, "--value")) {
                value = args.next() orelse return error.MissingValue;
            } else if (topic == null) {
                topic = option;
            } else if (key == null) {
                key = option;
            } else if (value == null) {
                value = option;
            } else return error.UnknownOption;
        }
        request = .{ .produce = .{
            .topic = .{ .bytes = topic orelse return error.MissingTopic },
            .key = .{ .bytes = key orelse return error.MissingKey },
            .value = .{ .bytes = value orelse return error.MissingValue },
            .headers = blank,
        } };
    } else if (std.mem.eql(u8, command, "consume")) {
        var topic: ?[]const u8 = null;
        var group: ?[]const u8 = null;
        var max: i32 = 100;
        var should_commit = false;
        while (args.next()) |option| {
            if (std.mem.eql(u8, option, "--topic")) {
                topic = args.next() orelse return error.MissingTopic;
            } else if (std.mem.eql(u8, option, "--group")) {
                group = args.next() orelse return error.MissingGroup;
            } else if (std.mem.eql(u8, option, "--max")) {
                max = try std.fmt.parseInt(i32, args.next() orelse return error.MissingMax, 10);
            } else if (std.mem.eql(u8, option, "--commit")) {
                should_commit = true;
            } else if (topic == null) {
                topic = option;
            } else if (group == null) {
                group = option;
            } else {
                max = try std.fmt.parseInt(i32, option, 10);
            }
        }
        const topic_value = topic orelse return error.MissingTopic;
        const group_value = group orelse return error.MissingGroup;
        request = .{ .fetch = .{ .topic = .{ .bytes = topic_value }, .group = .{ .bytes = group_value }, .max = max } };
        var response = try client.call(request);
        defer freeResponse(allocator, &response);
        if (!response.ok) return error.RequestFailed;
        std.debug.print("consume group={s} count={d}\n", .{ group_value, response.messages.len });
        var next_offset: ?i64 = null;
        for (response.messages) |message| {
            std.debug.print("  offset={d} key={s} value={s}\n", .{ message.offset, message.key.bytes, message.value.bytes });
            next_offset = message.offset + 1;
        }
        if (should_commit and next_offset != null) {
            const commit_request: Request = .{ .commit = .{ .topic = .{ .bytes = topic_value }, .group = .{ .bytes = group_value }, .offset = next_offset.? } };
            var commit_response = try client.call(commit_request);
            defer freeResponse(allocator, &commit_response);
            if (!commit_response.ok) return error.RequestFailed;
            std.debug.print("  committed offset={d}\n", .{next_offset.?});
        }
        return;
    } else if (std.mem.eql(u8, command, "list")) {
        request = .{ .list_topics = .{} };
    } else if (std.mem.eql(u8, command, "stats")) {
        request = .{ .stats = .{} };
    } else if (std.mem.eql(u8, command, "ping")) {
        request = .{ .ping = .{} };
    } else if (std.mem.eql(u8, command, "shutdown")) {
        request = .{ .shutdown = .{} };
    } else return error.UnknownCommand;
    if (args.next() != null) return error.UnknownOption;
    var response = try client.call(request);
    defer freeResponse(allocator, &response);
    if (!response.ok) return error.RequestFailed;
    std.debug.print("{s}: {s}\n", .{ command, response.message.bytes });
    if (response.message_count != 0 or response.topic_count != 0 or response.group_count != 0) {
        std.debug.print("  topics={d} messages={d} groups={d}\n", .{ response.topic_count, response.message_count, response.group_count });
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
