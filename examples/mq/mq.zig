const std = @import("std");
const memorypack = @import("memorypack");

pub const Options = struct {
    data_dir: []const u8,
    durability: Durability = .fsync_every_write,
    max_frame_size: usize = 16 * 1024 * 1024,
    max_batch_size: usize = 1024,
};

pub const Durability = enum {
    fsync_every_write,
    buffered,
};

pub const Error = error{
    StoreClosed,
    InvalidTopic,
    TopicNotFound,
    GroupNotFound,
    FrameTooLarge,
    BatchTooLarge,
    CorruptOffsets,
    InvalidOffset,
} || std.mem.Allocator.Error;

pub const Message = struct {
    pub const memorypack_version_tolerant = true;

    offset: i64,
    timestamp: i64,
    key: memorypack.Str,
    value: memorypack.Str,
    headers: []const memorypack.Str,
};

pub const Produce = struct {
    topic: memorypack.Str,
    key: memorypack.Str,
    value: memorypack.Str,
    headers: []const memorypack.Str,
};

pub const GroupOffset = struct {
    group: memorypack.Str,
    topic: memorypack.Str,
    offset: i64,
};

const OffsetSnapshot = struct {
    pub const memorypack_version_tolerant = true;

    offsets: []const GroupOffset,
};

const TopicSnapshot = struct {
    pub const memorypack_version_tolerant = true;

    names: []const memorypack.Str,
};

const Sink = struct {
    list: *std.ArrayList(u8),
    allocator: std.mem.Allocator,

    pub fn writeAll(self: Sink, bytes: []const u8) !void {
        try self.list.appendSlice(self.allocator, bytes);
    }
};

const ChunkReader = struct {
    bytes: []const u8,
    position: usize = 0,

    pub fn read(self: *ChunkReader, destination: []u8) !usize {
        if (self.position == self.bytes.len) return 0;
        const count = @min(@min(destination.len, 2), self.bytes.len - self.position);
        @memcpy(destination[0..count], self.bytes[self.position..][0..count]);
        self.position += count;
        return count;
    }
};

const Topic = struct {
    name: []u8,
    path: []u8,
    next_offset: i64 = 0,
    message_count: usize = 0,
};

const max_topic_name = 255;

pub const Stats = struct {
    topics: usize,
    messages: usize,
    groups: usize,
};

pub const Broker = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    options: Options,
    data_dir: []u8,
    topics_dir: []u8,
    offsets_path: []u8,
    offsets_temp_path: []u8,
    topics_path: []u8,
    topics_temp_path: []u8,
    topics: std.ArrayList(Topic),
    offsets: std.ArrayList(GroupOffset),
    mutex: std.Io.Mutex = .init,
    closed: bool = false,

    /// Opens a broker directory and recovers all topic logs and offsets.
    pub fn open(io: std.Io, allocator: std.mem.Allocator, options: Options) !Broker {
        if (options.data_dir.len == 0) return error.InvalidTopic;
        std.Io.Dir.cwd().createDirPath(io, options.data_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
        const topics_dir = try std.fmt.allocPrint(allocator, "{s}/topics", .{options.data_dir});
        errdefer allocator.free(topics_dir);
        std.Io.Dir.cwd().createDirPath(io, topics_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
        var broker = Broker{
            .allocator = allocator,
            .io = io,
            .options = options,
            .data_dir = try allocator.dupe(u8, options.data_dir),
            .topics_dir = topics_dir,
            .offsets_path = try std.fmt.allocPrint(allocator, "{s}/offsets.bin", .{options.data_dir}),
            .offsets_temp_path = try std.fmt.allocPrint(allocator, "{s}/offsets.tmp", .{options.data_dir}),
            .topics_path = try std.fmt.allocPrint(allocator, "{s}/topics.bin", .{options.data_dir}),
            .topics_temp_path = try std.fmt.allocPrint(allocator, "{s}/topics.tmp", .{options.data_dir}),
            .topics = .empty,
            .offsets = .empty,
        };
        errdefer broker.deinit();
        try broker.loadTopics();
        try broker.loadOffsets();
        return broker;
    }

    /// Closes the broker and releases all owned memory. Repeated calls are safe.
    pub fn deinit(self: *Broker) void {
        self.mutex.lockUncancelable(self.io);
        if (self.closed) {
            self.mutex.unlock(self.io);
            return;
        }
        self.closed = true;
        for (self.topics.items) |topic| {
            self.allocator.free(topic.name);
            self.allocator.free(topic.path);
        }
        self.topics.deinit(self.allocator);
        for (self.offsets.items) |offset| deinitGroupOffset(self.allocator, offset);
        self.offsets.deinit(self.allocator);
        self.allocator.free(self.data_dir);
        self.allocator.free(self.topics_dir);
        self.allocator.free(self.offsets_path);
        self.allocator.free(self.offsets_temp_path);
        self.allocator.free(self.topics_path);
        self.allocator.free(self.topics_temp_path);
        self.mutex.unlock(self.io);
    }

    /// Creates a topic log if it does not already exist.
    pub fn createTopic(self: *Broker, name: []const u8) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.closed) return error.StoreClosed;
        if (!validTopic(name)) return error.InvalidTopic;
        if (self.findTopic(name) != null) return;
        try self.addTopic(name);
        try self.persistTopicsLocked();
    }

    /// Appends a durable message and returns its assigned monotonic offset.
    pub fn produce(self: *Broker, input: Produce) !i64 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.closed) return error.StoreClosed;
        const topic = self.findTopic(input.topic.bytes) orelse return error.TopicNotFound;
        const message = Message{
            .offset = topic.next_offset,
            .timestamp = @intCast(@divTrunc(std.Io.Clock.real.now(self.io).nanoseconds, 1_000_000_000)),
            .key = input.key,
            .value = input.value,
            .headers = input.headers,
        };
        try self.appendMessage(topic, message);
        topic.next_offset += 1;
        topic.message_count += 1;
        return message.offset;
    }

    /// Fetches at most `max` messages at or after a group's committed offset.
    pub fn fetch(self: *Broker, topic_name: []const u8, group: []const u8, max: usize) ![]Message {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.closed) return error.StoreClosed;
        if (max == 0 or max > self.options.max_batch_size) return error.BatchTooLarge;
        const topic = self.findTopic(topic_name) orelse return error.TopicNotFound;
        const start = self.committedOffsetLocked(group, topic_name);
        return self.readMessages(topic, start, max);
    }

    /// Commits a consumer group's next offset durably.
    pub fn commit(self: *Broker, group: []const u8, topic_name: []const u8, offset: i64) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.closed) return error.StoreClosed;
        if (offset < 0) return error.InvalidOffset;
        _ = self.findTopic(topic_name) orelse return error.TopicNotFound;
        if (self.findOffset(group, topic_name)) |entry| {
            if (offset < entry.offset) return error.InvalidOffset;
            entry.offset = offset;
        } else {
            try self.offsets.append(self.allocator, .{
                .group = .{ .bytes = try self.allocator.dupe(u8, group) },
                .topic = .{ .bytes = try self.allocator.dupe(u8, topic_name) },
                .offset = offset,
            });
        }
        try self.persistOffsetsLocked();
    }

    /// Lists topic names in stable insertion order.
    pub fn listTopics(self: *Broker, allocator: std.mem.Allocator) ![][]const u8 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.closed) return error.StoreClosed;
        const result = try allocator.alloc([]const u8, self.topics.items.len);
        errdefer allocator.free(result);
        for (result, self.topics.items) |*destination, topic| {
            destination.* = topic.name;
        }
        return result;
    }

    /// Returns topic and consumer-group counts for observability.
    pub fn stats(self: *Broker) !Stats {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.closed) return error.StoreClosed;
        var messages: usize = 0;
        for (self.topics.items) |topic| messages += topic.message_count;
        return .{ .topics = self.topics.items.len, .messages = messages, .groups = self.offsets.items.len };
    }

    fn addTopic(self: *Broker, name: []const u8) !void {
        const owned_name = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(owned_name);
        const path = try std.fmt.allocPrint(self.allocator, "{s}/{s}.log", .{ self.topics_dir, name });
        errdefer self.allocator.free(path);
        var topic = Topic{ .name = owned_name, .path = path };
        errdefer {
            self.allocator.free(topic.name);
            self.allocator.free(topic.path);
        }
        try self.recoverTopic(&topic);
        try self.topics.append(self.allocator, topic);
    }

    fn loadTopics(self: *Broker) !void {
        const bytes = readFile(self.io, self.allocator, self.topics_path) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
        defer self.allocator.free(bytes);
        var snapshot = memorypack.decode(TopicSnapshot, self.allocator, bytes) catch return error.CorruptOffsets;
        defer memorypack.deinit(TopicSnapshot, self.allocator, &snapshot);
        for (snapshot.names) |name| try self.addTopic(name.bytes);
    }

    fn persistTopicsLocked(self: *Broker) !void {
        const names = try self.allocator.alloc(memorypack.Str, self.topics.items.len);
        defer self.allocator.free(names);
        for (names, self.topics.items) |*destination, topic| destination.* = .{ .bytes = topic.name };
        const snapshot = TopicSnapshot{ .names = names };
        const bytes = try memorypack.encode(self.allocator, snapshot);
        defer self.allocator.free(bytes);
        try std.Io.Dir.cwd().writeFile(self.io, .{ .sub_path = self.topics_temp_path, .data = bytes });
        var file = try std.Io.Dir.cwd().openFile(self.io, self.topics_temp_path, .{ .mode = .read_only });
        defer file.close(self.io);
        if (self.options.durability == .fsync_every_write) try file.sync(self.io);
        try std.Io.Dir.rename(std.Io.Dir.cwd(), self.topics_temp_path, std.Io.Dir.cwd(), self.topics_path, self.io);
    }

    fn recoverTopic(self: *Broker, topic: *Topic) !void {
        const bytes = readFile(self.io, self.allocator, topic.path) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
        defer self.allocator.free(bytes);
        var position: usize = 0;
        var valid_end: usize = 0;
        while (position < bytes.len) {
            if (bytes.len - position < 8) break;
            const length = std.mem.readInt(u32, bytes[position..][0..4], .little);
            const crc = std.mem.readInt(u32, bytes[position + 4 ..][0..4], .little);
            position += 8;
            if (length > self.options.max_frame_size or length > bytes.len - position) break;
            const payload = bytes[position..][0..@intCast(length)];
            position += payload.len;
            if (std.hash.Crc32.hash(payload) != crc) break;
            var reader = ChunkReader{ .bytes = payload };
            var message = memorypack.decodeFromReader(Message, self.allocator, &reader) catch break;
            defer memorypack.deinit(Message, self.allocator, &message);
            if (message.offset != topic.next_offset) break;
            topic.next_offset += 1;
            topic.message_count += 1;
            valid_end = position;
        }
        if (valid_end < bytes.len) {
            var file = try std.Io.Dir.cwd().createFile(self.io, topic.path, .{ .truncate = true });
            defer file.close(self.io);
            var buffer: [4096]u8 = undefined;
            var writer = file.writerStreaming(self.io, &buffer);
            try writer.interface.writeAll(bytes[0..valid_end]);
            try writer.interface.flush();
            if (self.options.durability == .fsync_every_write) try file.sync(self.io);
        }
    }

    fn appendMessage(self: *Broker, topic: *Topic, message: Message) !void {
        var payload: std.ArrayList(u8) = .empty;
        defer payload.deinit(self.allocator);
        try memorypack.encodeTo(self.allocator, message, Sink{ .list = &payload, .allocator = self.allocator });
        if (payload.items.len > self.options.max_frame_size or payload.items.len > std.math.maxInt(u32)) {
            return error.FrameTooLarge;
        }
        var file = try std.Io.Dir.cwd().createFile(self.io, topic.path, .{ .truncate = false });
        defer file.close(self.io);
        const size = try file.stat(self.io);
        var buffer: [4096]u8 = undefined;
        var writer = file.writerStreaming(self.io, &buffer);
        try writer.seekTo(size.size);
        var header: [8]u8 = undefined;
        std.mem.writeInt(u32, header[0..4], @intCast(payload.items.len), .little);
        std.mem.writeInt(u32, header[4..8], std.hash.Crc32.hash(payload.items), .little);
        try writer.interface.writeAll(&header);
        try writer.interface.writeAll(payload.items);
        try writer.interface.flush();
        if (self.options.durability == .fsync_every_write) try file.sync(self.io);
    }

    fn readMessages(self: *Broker, topic: *const Topic, start: i64, max: usize) ![]Message {
        const bytes = try readFile(self.io, self.allocator, topic.path);
        defer self.allocator.free(bytes);
        var result: std.ArrayList(Message) = .empty;
        errdefer {
            for (result.items) |*message| memorypack.deinit(Message, self.allocator, message);
            result.deinit(self.allocator);
        }
        var position: usize = 0;
        while (position < bytes.len and result.items.len < max) {
            if (bytes.len - position < 8) break;
            const length = std.mem.readInt(u32, bytes[position..][0..4], .little);
            const crc = std.mem.readInt(u32, bytes[position + 4 ..][0..4], .little);
            position += 8;
            if (length > self.options.max_frame_size or length > bytes.len - position) break;
            const payload = bytes[position..][0..@intCast(length)];
            position += payload.len;
            if (std.hash.Crc32.hash(payload) != crc) break;
            var reader = ChunkReader{ .bytes = payload };
            var message = memorypack.decodeFromReader(Message, self.allocator, &reader) catch break;
            if (message.offset >= start) try result.append(self.allocator, message) else memorypack.deinit(Message, self.allocator, &message);
        }
        return result.toOwnedSlice(self.allocator);
    }

    fn loadOffsets(self: *Broker) !void {
        const bytes = readFile(self.io, self.allocator, self.offsets_path) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
        defer self.allocator.free(bytes);
        var snapshot = memorypack.decode(OffsetSnapshot, self.allocator, bytes) catch return error.CorruptOffsets;
        defer memorypack.deinit(OffsetSnapshot, self.allocator, &snapshot);
        for (snapshot.offsets) |entry| {
            try self.offsets.append(self.allocator, .{
                .group = .{ .bytes = try self.allocator.dupe(u8, entry.group.bytes) },
                .topic = .{ .bytes = try self.allocator.dupe(u8, entry.topic.bytes) },
                .offset = entry.offset,
            });
        }
    }

    fn persistOffsetsLocked(self: *Broker) !void {
        const snapshot = OffsetSnapshot{ .offsets = self.offsets.items };
        const bytes = try memorypack.encode(self.allocator, snapshot);
        defer self.allocator.free(bytes);
        try std.Io.Dir.cwd().writeFile(self.io, .{ .sub_path = self.offsets_temp_path, .data = bytes });
        var file = try std.Io.Dir.cwd().openFile(self.io, self.offsets_temp_path, .{ .mode = .read_only });
        defer file.close(self.io);
        if (self.options.durability == .fsync_every_write) try file.sync(self.io);
        try std.Io.Dir.rename(std.Io.Dir.cwd(), self.offsets_temp_path, std.Io.Dir.cwd(), self.offsets_path, self.io);
    }

    fn findTopic(self: *Broker, name: []const u8) ?*Topic {
        for (self.topics.items) |*topic| {
            if (std.mem.eql(u8, topic.name, name)) return topic;
        }
        return null;
    }

    fn findOffset(self: *Broker, group: []const u8, topic: []const u8) ?*GroupOffset {
        for (self.offsets.items) |*entry| {
            if (std.mem.eql(u8, entry.group.bytes, group) and std.mem.eql(u8, entry.topic.bytes, topic)) return entry;
        }
        return null;
    }

    fn committedOffsetLocked(self: *Broker, group: []const u8, topic: []const u8) i64 {
        return if (self.findOffset(group, topic)) |entry| entry.offset else 0;
    }
};

fn validTopic(name: []const u8) bool {
    if (name.len == 0 or name.len > max_topic_name) return false;
    for (name) |byte| {
        if (!(std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '_' or byte == '.')) return false;
    }
    return true;
}

fn deinitGroupOffset(allocator: std.mem.Allocator, entry: GroupOffset) void {
    allocator.free(entry.group.bytes);
    allocator.free(entry.topic.bytes);
}

fn readFile(io: std.Io, allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(256 * 1024 * 1024));
}

fn freeMessages(allocator: std.mem.Allocator, messages: []Message) void {
    for (messages) |*message| memorypack.deinit(Message, allocator, message);
    allocator.free(messages);
}

test "durable topic append and recovery" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    const dir = "zig-cache/mq-test-recovery";
    std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    var broker = try Broker.open(io, allocator, .{ .data_dir = dir });
    try broker.createTopic("orders");
    _ = try broker.produce(.{ .topic = .{ .bytes = "orders" }, .key = .{ .bytes = "a" }, .value = .{ .bytes = "one" }, .headers = &.{} });
    _ = try broker.produce(.{ .topic = .{ .bytes = "orders" }, .key = .{ .bytes = "b" }, .value = .{ .bytes = "two" }, .headers = &.{} });
    broker.deinit();
    var reopened = try Broker.open(io, allocator, .{ .data_dir = dir });
    defer reopened.deinit();
    const messages = try reopened.fetch("orders", "g", 10);
    defer freeMessages(allocator, messages);
    try std.testing.expectEqual(@as(usize, 2), messages.len);
    try std.testing.expectEqual(@as(i64, 1), messages[1].offset);
}

test "consumer commits resume and uncommitted fetch redelivers" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    const dir = "zig-cache/mq-test-groups";
    std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    var broker = try Broker.open(io, allocator, .{ .data_dir = dir });
    defer broker.deinit();
    try broker.createTopic("events");
    for (0..3) |i| _ = try broker.produce(.{ .topic = .{ .bytes = "events" }, .key = .{ .bytes = "" }, .value = .{ .bytes = if (i == 0) "a" else if (i == 1) "b" else "c" }, .headers = &.{} });
    const first = try broker.fetch("events", "payments", 2);
    defer freeMessages(allocator, first);
    try broker.commit("payments", "events", 2);
    const second = try broker.fetch("events", "payments", 2);
    defer freeMessages(allocator, second);
    try std.testing.expectEqual(@as(usize, 1), second.len);
    broker.deinit();
    var restarted = try Broker.open(io, allocator, .{ .data_dir = dir });
    defer restarted.deinit();
    const after_restart = try restarted.fetch("events", "payments", 2);
    defer freeMessages(allocator, after_restart);
    try std.testing.expectEqual(@as(usize, 1), after_restart.len);
    const redelivered = try restarted.fetch("events", "audit", 2);
    defer freeMessages(allocator, redelivered);
    try std.testing.expectEqual(@as(i64, 0), redelivered[0].offset);
}

test "corrupt tail preserves prior messages" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    const dir = "zig-cache/mq-test-corrupt";
    std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    var broker = try Broker.open(io, allocator, .{ .data_dir = dir });
    try broker.createTopic("safe");
    _ = try broker.produce(.{ .topic = .{ .bytes = "safe" }, .key = .{ .bytes = "" }, .value = .{ .bytes = "ok" }, .headers = &.{} });
    broker.deinit();
    var file = try std.Io.Dir.cwd().openFile(io, "zig-cache/mq-test-corrupt/topics/safe.log", .{ .mode = .read_write });
    const stat = try file.stat(io);
    var buffer: [16]u8 = undefined;
    var writer = file.writerStreaming(io, &buffer);
    try writer.seekTo(stat.size);
    try writer.interface.writeAll(&.{ 32, 0, 0, 0, 0, 0, 0, 0, 1 });
    try writer.interface.flush();
    file.close(io);
    var reopened = try Broker.open(io, allocator, .{ .data_dir = dir });
    defer reopened.deinit();
    try std.testing.expectEqual(@as(usize, 1), (try reopened.stats()).messages);
    _ = try reopened.produce(.{ .topic = .{ .bytes = "safe" }, .key = .{ .bytes = "" }, .value = .{ .bytes = "after-recovery" }, .headers = &.{} });
    try std.testing.expectEqual(@as(usize, 2), (try reopened.stats()).messages);
}

const ConcurrentProduceContext = struct {
    broker: *Broker,
    failed: *std.atomic.Value(bool),
};

fn concurrentProduce(context: *ConcurrentProduceContext) void {
    for (0..8) |_| {
        _ = context.broker.produce(.{
            .topic = .{ .bytes = "parallel" },
            .key = .{ .bytes = "" },
            .value = .{ .bytes = "payload" },
            .headers = &.{},
        }) catch {
            context.failed.store(true, .release);
            return;
        };
    }
}

test "concurrent producers preserve a complete topic log" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    const dir = "zig-cache/mq-test-concurrent";
    std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    var broker = try Broker.open(io, allocator, .{ .data_dir = dir });
    defer broker.deinit();
    try broker.createTopic("parallel");
    var failed = std.atomic.Value(bool).init(false);
    var context = ConcurrentProduceContext{ .broker = &broker, .failed = &failed };
    var threads: [4]std.Thread = undefined;
    for (&threads) |*thread| {
        thread.* = try std.Thread.spawn(.{}, concurrentProduce, .{&context});
    }
    for (threads) |thread| thread.join();
    try std.testing.expect(!failed.load(.acquire));
    try std.testing.expectEqual(@as(usize, 32), (try broker.stats()).messages);
}
