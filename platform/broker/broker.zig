const std = @import("std");
const memorypack = @import("memorypack");
const core = @import("core");

pub const Options = struct {
    data_dir: []const u8,
    fsync: bool = true,
    max_frame_size: usize = 16 * 1024 * 1024,
};

pub const Event = struct {
    pub const memorypack_version_tolerant = true;
    topic: memorypack.Str,
    offset: i64,
    timestamp: i64,
    payload: memorypack.Str,
};

pub const Received = struct {
    event: Event,
};

const Offset = struct {
    topic: memorypack.Str,
    group: memorypack.Str,
    offset: i64,
};

pub const Stats = struct {
    events: usize,
    groups: usize,
};

pub const Broker = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    options: Options,
    dir: []u8,
    log_path: []u8,
    offsets_path: []u8,
    events: std.ArrayList(Event),
    offsets: std.ArrayList(Offset),
    mutex: std.Io.Mutex = .init,
    closed: bool = false,

    /// Opens the internal durable event broker and replays its logs.
    pub fn open(io: std.Io, allocator: std.mem.Allocator, options: Options) !Broker {
        std.Io.Dir.cwd().createDirPath(io, options.data_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
        const log = try std.fmt.allocPrint(allocator, "{s}/events.log", .{options.data_dir});
        errdefer allocator.free(log);
        const offsets = try std.fmt.allocPrint(allocator, "{s}/consumer-offsets.bin", .{options.data_dir});
        errdefer allocator.free(offsets);
        var broker = Broker{
            .allocator = allocator,
            .io = io,
            .options = options,
            .dir = try allocator.dupe(u8, options.data_dir),
            .log_path = log,
            .offsets_path = offsets,
            .events = .empty,
            .offsets = .empty,
        };
        errdefer broker.deinit();
        try broker.load();
        return broker;
    }

    /// Releases broker state and is safe to call twice.
    pub fn deinit(self: *Broker) void {
        self.mutex.lockUncancelable(self.io);
        if (self.closed) {
            self.mutex.unlock(self.io);
            return;
        }
        self.closed = true;
        for (self.events.items) |*event| deinitEvent(self.allocator, event);
        for (self.offsets.items) |*offset| deinitOffset(self.allocator, offset);
        self.events.deinit(self.allocator);
        self.offsets.deinit(self.allocator);
        self.allocator.free(self.dir);
        self.allocator.free(self.log_path);
        self.allocator.free(self.offsets_path);
        self.mutex.unlock(self.io);
    }

    /// Publishes a durable event and returns its topic-local offset.
    pub fn publish(self: *Broker, topic: []const u8, payload: []const u8) !i64 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.closed or topic.len == 0) return error.InvalidInput;
        var event = Event{
            .topic = .{ .bytes = try self.allocator.dupe(u8, topic) },
            .offset = self.nextOffset(topic),
            .timestamp = @intCast(@divTrunc(std.Io.Clock.real.now(self.io).nanoseconds, 1_000_000_000)),
            .payload = .{ .bytes = try self.allocator.dupe(u8, payload) },
        };
        errdefer deinitEvent(self.allocator, &event);
        var file = try std.Io.Dir.cwd().createFile(self.io, self.log_path, .{ .truncate = false });
        defer file.close(self.io);
        try core.writeDiskFrame(&file, self.io, self.allocator, self.options.max_frame_size, event, self.options.fsync);
        try self.events.append(self.allocator, event);
        return event.offset;
    }

    /// Fetches uncommitted events for a group without advancing its offset.
    pub fn fetch(self: *Broker, topic: []const u8, group: []const u8, max: usize) ![]Event {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.closed or max == 0 or max > 10000) return error.InvalidInput;
        const start = self.committed(topic, group);
        var result: std.ArrayList(Event) = .empty;
        errdefer freeEvents(self.allocator, result.items);
        for (self.events.items) |event| {
            if (std.mem.eql(u8, event.topic.bytes, topic) and event.offset >= start) {
                try result.append(self.allocator, try cloneEvent(self.allocator, event));
                if (result.items.len == max) break;
            }
        }
        return result.toOwnedSlice(self.allocator);
    }

    /// Commits the next offset for a consumer group durably.
    pub fn commit(self: *Broker, topic: []const u8, group: []const u8, offset: i64) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.closed or offset < 0) return error.InvalidInput;
        if (self.findOffset(topic, group)) |entry| {
            entry.offset = offset;
        } else {
            try self.offsets.append(self.allocator, .{ .topic = .{ .bytes = try self.allocator.dupe(u8, topic) }, .group = .{ .bytes = try self.allocator.dupe(u8, group) }, .offset = offset });
        }
        try self.persistOffsets();
    }

    /// Returns event and consumer-group metrics.
    pub fn stats(self: *Broker) !Stats {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return .{ .events = self.events.items.len, .groups = self.offsets.items.len };
    }

    fn load(self: *Broker) !void {
        const events = core.readDiskFrames(Event, self.io, self.allocator, self.log_path, self.options.max_frame_size) catch |err| switch (err) {
            error.FileNotFound => &[_]Event{},
            else => return err,
        };
        for (events) |event| try self.events.append(self.allocator, event);
        if (events.len > 0) self.allocator.free(events);
        const bytes = std.Io.Dir.cwd().readFileAlloc(self.io, self.offsets_path, self.allocator, .limited(64 * 1024 * 1024)) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
        defer self.allocator.free(bytes);
        var decoded = memorypack.decode([]const Offset, self.allocator, bytes) catch return error.CorruptData;
        defer memorypack.deinit([]const Offset, self.allocator, &decoded);
        for (decoded) |offset| try self.offsets.append(self.allocator, .{ .topic = .{ .bytes = try self.allocator.dupe(u8, offset.topic.bytes) }, .group = .{ .bytes = try self.allocator.dupe(u8, offset.group.bytes) }, .offset = offset.offset });
    }

    fn persistOffsets(self: *Broker) !void {
        const bytes = try memorypack.encode(self.allocator, self.offsets.items);
        defer self.allocator.free(bytes);
        try std.Io.Dir.cwd().writeFile(self.io, .{ .sub_path = self.offsets_path, .data = bytes });
        var file = try std.Io.Dir.cwd().openFile(self.io, self.offsets_path, .{ .mode = .read_only });
        defer file.close(self.io);
        if (self.options.fsync) try file.sync(self.io);
    }

    fn nextOffset(self: *Broker, topic: []const u8) i64 {
        var next: i64 = 0;
        for (self.events.items) |event| {
            if (std.mem.eql(u8, event.topic.bytes, topic) and event.offset >= next) next = event.offset + 1;
        }
        return next;
    }

    fn committed(self: *Broker, topic: []const u8, group: []const u8) i64 {
        for (self.offsets.items) |offset| if (std.mem.eql(u8, offset.topic.bytes, topic) and std.mem.eql(u8, offset.group.bytes, group)) return offset.offset;
        return 0;
    }

    fn findOffset(self: *Broker, topic: []const u8, group: []const u8) ?*Offset {
        for (self.offsets.items) |*offset| if (std.mem.eql(u8, offset.topic.bytes, topic) and std.mem.eql(u8, offset.group.bytes, group)) return offset;
        return null;
    }
};

pub fn cloneEvent(allocator: std.mem.Allocator, event: Event) !Event {
    return .{ .topic = .{ .bytes = try allocator.dupe(u8, event.topic.bytes) }, .offset = event.offset, .timestamp = event.timestamp, .payload = .{ .bytes = try allocator.dupe(u8, event.payload.bytes) } };
}

pub fn deinitEvent(allocator: std.mem.Allocator, event: *Event) void {
    allocator.free(event.topic.bytes);
    allocator.free(event.payload.bytes);
}

fn deinitOffset(allocator: std.mem.Allocator, offset: *Offset) void {
    allocator.free(offset.topic.bytes);
    allocator.free(offset.group.bytes);
}

fn freeEvents(allocator: std.mem.Allocator, events: []Event) void {
    for (events) |*event| deinitEvent(allocator, event);
    allocator.free(events);
}

test "broker publish fetch commit and redelivery" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    const dir = "zig-cache/platform-broker";
    std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    var broker = try Broker.open(io, allocator, .{ .data_dir = dir });
    defer broker.deinit();
    _ = try broker.publish("telemetry", "reading");
    const first = try broker.fetch("telemetry", "alerts", 10);
    defer freeEvents(allocator, first);
    try std.testing.expectEqual(@as(usize, 1), first.len);
    try broker.commit("telemetry", "alerts", 1);
    const second = try broker.fetch("telemetry", "alerts", 10);
    defer freeEvents(allocator, second);
    try std.testing.expectEqual(@as(usize, 0), second.len);
}
