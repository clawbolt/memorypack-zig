const std = @import("std");
const memorypack = @import("memorypack");

pub const Options = struct {
    data_dir: []const u8,
    fsync: bool = true,
};

pub const Entry = struct {
    pub const memorypack_version_tolerant = true;
    seq: i64,
    timestamp: i64,
    actor: memorypack.Str,
    action: memorypack.Str,
    detail: memorypack.Str,
    prev_hash: [32]u8,
    entry_hash: [32]u8,
};

const Core = struct {
    seq: i64,
    timestamp: i64,
    actor: memorypack.Str,
    action: memorypack.Str,
    detail: memorypack.Str,
};

pub const Store = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []u8,
    entries: std.ArrayList(Entry),
    mutex: std.Io.Mutex = .init,
    closed: bool = false,

    /// Opens and recovers the iothub audit chain.
    pub fn open(io: std.Io, allocator: std.mem.Allocator, options: Options) !Store {
        std.Io.Dir.cwd().createDirPath(io, options.data_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
        const path = try std.fmt.allocPrint(allocator, "{s}/iothub-audit.log", .{options.data_dir});
        errdefer allocator.free(path);
        var store = Store{ .allocator = allocator, .io = io, .path = path, .entries = .empty };
        errdefer store.deinit();
        const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(256 * 1024 * 1024)) catch |err| switch (err) {
            error.FileNotFound => return store,
            else => return err,
        };
        defer allocator.free(bytes);
        var position: usize = 0;
        while (position < bytes.len) {
            if (bytes.len - position < 8) break;
            const length = std.mem.readInt(u32, bytes[position..][0..4], .little);
            const crc = std.mem.readInt(u32, bytes[position + 4 ..][0..4], .little);
            position += 8;
            if (length > bytes.len - position) break;
            const payload = bytes[position..][0..@intCast(length)];
            position += payload.len;
            if (std.hash.Crc32.hash(payload) != crc) break;
            const entry = memorypack.decode(Entry, allocator, payload) catch break;
            try store.entries.append(allocator, entry);
        }
        return store;
    }

    /// Releases the audit chain safely.
    pub fn deinit(self: *Store) void {
        self.mutex.lockUncancelable(self.io);
        if (self.closed) {
            self.mutex.unlock(self.io);
            return;
        }
        self.closed = true;
        for (self.entries.items) |*entry| deinitEntry(self.allocator, entry);
        self.entries.deinit(self.allocator);
        self.allocator.free(self.path);
        self.mutex.unlock(self.io);
    }

    /// Appends a cryptographically linked audit action.
    pub fn append(self: *Store, actor: []const u8, action: []const u8, detail: []const u8) !i64 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.closed) return error.StoreClosed;
        const prev = if (self.entries.items.len == 0) [_]u8{0} ** 32 else self.entries.items[self.entries.items.len - 1].entry_hash;
        var entry = Entry{ .seq = @intCast(self.entries.items.len), .timestamp = @intCast(@divTrunc(std.Io.Clock.real.now(self.io).nanoseconds, 1_000_000_000)), .actor = .{ .bytes = try self.allocator.dupe(u8, actor) }, .action = .{ .bytes = try self.allocator.dupe(u8, action) }, .detail = .{ .bytes = try self.allocator.dupe(u8, detail) }, .prev_hash = prev, .entry_hash = undefined };
        errdefer deinitEntry(self.allocator, &entry);
        entry.entry_hash = try hashCore(self.allocator, prev, .{ .seq = entry.seq, .timestamp = entry.timestamp, .actor = entry.actor, .action = entry.action, .detail = entry.detail });
        var file = try std.Io.Dir.cwd().createFile(self.io, self.path, .{ .truncate = false });
        defer file.close(self.io);
        const payload = try memorypack.encode(self.allocator, entry);
        defer self.allocator.free(payload);
        var buffer: [4096]u8 = undefined;
        var writer = file.writerStreaming(self.io, &buffer);
        const stat = try file.stat(self.io);
        try writer.seekTo(stat.size);
        var header: [8]u8 = undefined;
        std.mem.writeInt(u32, header[0..4], @intCast(payload.len), .little);
        std.mem.writeInt(u32, header[4..8], std.hash.Crc32.hash(payload), .little);
        try writer.interface.writeAll(&header);
        try writer.interface.writeAll(payload);
        try writer.interface.flush();
        try file.sync(self.io);
        try self.entries.append(self.allocator, entry);
        return entry.seq;
    }

    /// Verifies all sequence, linkage, and SHA-256 values.
    pub fn verify(self: *Store) !bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        var previous = [_]u8{0} ** 32;
        for (self.entries.items, 0..) |entry, index| {
            if (entry.seq != @as(i64, @intCast(index))) return false;
            if (!std.mem.eql(u8, &entry.prev_hash, &previous)) return false;
            const expected = try hashCore(self.allocator, entry.prev_hash, .{ .seq = entry.seq, .timestamp = entry.timestamp, .actor = entry.actor, .action = entry.action, .detail = entry.detail });
            if (!std.mem.eql(u8, &expected, &entry.entry_hash)) return false;
            previous = entry.entry_hash;
        }
        return true;
    }
};

fn hashCore(allocator: std.mem.Allocator, prev: [32]u8, core: Core) ![32]u8 {
    const bytes = try memorypack.encode(allocator, core);
    defer allocator.free(bytes);
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(&prev);
    hash.update(bytes);
    var result: [32]u8 = undefined;
    hash.final(&result);
    return result;
}

fn deinitEntry(allocator: std.mem.Allocator, entry: *Entry) void {
    allocator.free(entry.actor.bytes);
    allocator.free(entry.action.bytes);
    allocator.free(entry.detail.bytes);
}

test "iothub audit chain verifies" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    const dir = "zig-cache/iothub-audit";
    std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    var store = try Store.open(io, allocator, .{ .data_dir = dir });
    defer store.deinit();
    _ = try store.append("system", "device.register", "device-1");
    _ = try store.append("system", "reading.alert", "temperature");
    try std.testing.expect(try store.verify());
}
