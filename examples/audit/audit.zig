const std = @import("std");
const memorypack = @import("memorypack");

pub const Options = struct {
    data_dir: []const u8,
    durability: Durability = .fsync_every_write,
    max_frame_size: usize = 16 * 1024 * 1024,
};

pub const Durability = enum {
    fsync_every_write,
    buffered,
};

pub const Error = error{
    StoreClosed,
    InvalidInput,
    FrameTooLarge,
    ChainBroken,
    CorruptTail,
} || std.mem.Allocator.Error;

pub const Entry = struct {
    pub const memorypack_version_tolerant = true;

    seq: i64,
    timestamp: i64,
    actor: memorypack.Str,
    action: memorypack.Str,
    resource: memorypack.Str,
    detail: memorypack.Str,
    prev_hash: [32]u8,
    entry_hash: [32]u8,
};

const Core = struct {
    seq: i64,
    timestamp: i64,
    actor: memorypack.Str,
    action: memorypack.Str,
    resource: memorypack.Str,
    detail: memorypack.Str,
};

pub const Append = struct {
    actor: memorypack.Str,
    action: memorypack.Str,
    resource: memorypack.Str,
    detail: memorypack.Str,
};

pub const Query = struct {
    actor: ?[]const u8 = null,
    action: ?[]const u8 = null,
    start_seq: ?i64 = null,
    end_seq: ?i64 = null,
    offset: usize = 0,
    limit: usize = 100,
};

pub const VerifyResult = struct {
    intact: bool,
    entries: usize,
    broken_seq: i64,
    reason: memorypack.Str,
};

pub const Stats = struct {
    entries: usize,
    next_seq: i64,
    tip_hash: [32]u8,
};

const Sink = struct {
    list: *std.ArrayList(u8),
    allocator: std.mem.Allocator,

    pub fn writeAll(self: Sink, bytes: []const u8) !void {
        try self.list.appendSlice(self.allocator, bytes);
    }
};

const Reader = struct {
    bytes: []const u8,
    position: usize = 0,

    pub fn read(self: *Reader, destination: []u8) !usize {
        if (self.position == self.bytes.len) return 0;
        const count = @min(@min(destination.len, 2), self.bytes.len - self.position);
        @memcpy(destination[0..count], self.bytes[self.position..][0..count]);
        self.position += count;
        return count;
    }
};

pub const Store = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    options: Options,
    data_dir: []u8,
    log_path: []u8,
    entries: std.ArrayList(Entry),
    tip_hash: [32]u8 = [_]u8{0} ** 32,
    next_seq: i64 = 0,
    mutex: std.Io.Mutex = .init,
    closed: bool = false,

    /// Opens an audit directory, recovers complete framed records, and restores the chain tip.
    pub fn open(io: std.Io, allocator: std.mem.Allocator, options: Options) !Store {
        if (options.data_dir.len == 0) return error.InvalidInput;
        std.Io.Dir.cwd().createDirPath(io, options.data_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
        const log_path = try std.fmt.allocPrint(allocator, "{s}/audit.log", .{options.data_dir});
        errdefer allocator.free(log_path);
        var store = Store{
            .allocator = allocator,
            .io = io,
            .options = options,
            .data_dir = try allocator.dupe(u8, options.data_dir),
            .log_path = log_path,
            .entries = .empty,
        };
        errdefer store.deinit();
        try store.recover();
        return store;
    }

    /// Releases all resources. Repeated calls are safe.
    pub fn deinit(self: *Store) void {
        self.mutex.lockUncancelable(self.io);
        if (self.closed) {
            self.mutex.unlock(self.io);
            return;
        }
        self.closed = true;
        for (self.entries.items) |*entry| deinitEntry(self.allocator, entry);
        self.entries.deinit(self.allocator);
        self.allocator.free(self.data_dir);
        self.allocator.free(self.log_path);
        self.mutex.unlock(self.io);
    }

    /// Appends one durable, cryptographically chained audit entry and returns its sequence.
    pub fn append(self: *Store, input: Append) !i64 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.closed) return error.StoreClosed;
        if (!validText(input.actor.bytes) or !validText(input.action.bytes) or
            !validText(input.resource.bytes) or !validText(input.detail.bytes)) return error.InvalidInput;
        const entry = try self.makeEntry(input);
        errdefer deinitEntry(self.allocator, @constCast(&entry));
        try self.appendFrame(entry);
        try self.entries.append(self.allocator, entry);
        self.tip_hash = entry.entry_hash;
        self.next_seq += 1;
        return entry.seq;
    }

    /// Queries entries with optional actor/action and sequence range filters plus pagination.
    pub fn query(self: *Store, query_options: Query) ![]Entry {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.closed) return error.StoreClosed;
        if (query_options.limit == 0 or query_options.limit > 10000) return error.InvalidInput;
        if (query_options.end_seq != null and query_options.start_seq != null and query_options.end_seq.? < query_options.start_seq.?) return error.InvalidInput;
        var result: std.ArrayList(Entry) = .empty;
        errdefer {
            for (result.items) |*entry| deinitEntry(self.allocator, entry);
            result.deinit(self.allocator);
        }
        var skipped: usize = 0;
        for (self.entries.items) |entry| {
            if (query_options.actor) |actor| if (!std.mem.eql(u8, actor, entry.actor.bytes)) continue;
            if (query_options.action) |action| if (!std.mem.eql(u8, action, entry.action.bytes)) continue;
            if (query_options.start_seq) |start| if (entry.seq < start) continue;
            if (query_options.end_seq) |end| if (entry.seq > end) continue;
            if (skipped < query_options.offset) {
                skipped += 1;
                continue;
            }
            try result.append(self.allocator, try cloneEntry(self.allocator, entry));
            if (result.items.len == query_options.limit) break;
        }
        return result.toOwnedSlice(self.allocator);
    }

    /// Recomputes every hash and linkage, returning the first detected failure.
    pub fn verify(self: *Store) !VerifyResult {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.closed) return error.StoreClosed;
        var previous = [_]u8{0} ** 32;
        for (self.entries.items, 0..) |entry, index| {
            const expected_seq: i64 = @intCast(index);
            if (entry.seq != expected_seq) return broken(self.allocator, self.entries.items.len, entry.seq, "sequence gap or deletion");
            if (!std.mem.eql(u8, &entry.prev_hash, &previous)) return broken(self.allocator, self.entries.items.len, entry.seq, "previous hash linkage mismatch");
            const expected = try hashCore(self.allocator, entry.prev_hash, .{
                .seq = entry.seq,
                .timestamp = entry.timestamp,
                .actor = entry.actor,
                .action = entry.action,
                .resource = entry.resource,
                .detail = entry.detail,
            });
            if (!std.mem.eql(u8, &entry.entry_hash, &expected)) return broken(self.allocator, index, entry.seq, "entry hash mismatch");
            previous = entry.entry_hash;
        }
        return .{
            .intact = true,
            .entries = self.entries.items.len,
            .broken_seq = -1,
            .reason = .{ .bytes = try self.allocator.dupe(u8, "chain intact") },
        };
    }

    /// Returns entry count, next sequence, and the current chain tip.
    pub fn stats(self: *Store) !Stats {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.closed) return error.StoreClosed;
        return .{ .entries = self.entries.items.len, .next_seq = self.next_seq, .tip_hash = self.tip_hash };
    }

    fn makeEntry(self: *Store, input: Append) !Entry {
        var entry = Entry{
            .seq = self.next_seq,
            .timestamp = @intCast(@divTrunc(std.Io.Clock.real.now(self.io).nanoseconds, 1_000_000_000)),
            .actor = .{ .bytes = try self.allocator.dupe(u8, input.actor.bytes) },
            .action = .{ .bytes = try self.allocator.dupe(u8, input.action.bytes) },
            .resource = .{ .bytes = try self.allocator.dupe(u8, input.resource.bytes) },
            .detail = .{ .bytes = try self.allocator.dupe(u8, input.detail.bytes) },
            .prev_hash = self.tip_hash,
            .entry_hash = undefined,
        };
        errdefer deinitEntry(self.allocator, &entry);
        entry.entry_hash = try hashCore(self.allocator, entry.prev_hash, .{
            .seq = entry.seq,
            .timestamp = entry.timestamp,
            .actor = entry.actor,
            .action = entry.action,
            .resource = entry.resource,
            .detail = entry.detail,
        });
        return entry;
    }

    fn appendFrame(self: *Store, entry: Entry) !void {
        var payload: std.ArrayList(u8) = .empty;
        defer payload.deinit(self.allocator);
        try memorypack.encodeTo(self.allocator, entry, Sink{ .list = &payload, .allocator = self.allocator });
        if (payload.items.len > self.options.max_frame_size or payload.items.len > std.math.maxInt(u32)) return error.FrameTooLarge;
        var file = try std.Io.Dir.cwd().createFile(self.io, self.log_path, .{ .truncate = false });
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

    fn recover(self: *Store) !void {
        const bytes = std.Io.Dir.cwd().readFileAlloc(self.io, self.log_path, self.allocator, .limited(256 * 1024 * 1024)) catch |err| switch (err) {
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
            var reader = Reader{ .bytes = payload };
            const entry = memorypack.decodeFromReader(Entry, self.allocator, &reader) catch break;
            self.tip_hash = entry.entry_hash;
            self.next_seq = entry.seq + 1;
            try self.entries.append(self.allocator, entry);
            valid_end = position;
        }
        if (valid_end < bytes.len) {
            var file = try std.Io.Dir.cwd().createFile(self.io, self.log_path, .{ .truncate = true });
            defer file.close(self.io);
            var buffer: [4096]u8 = undefined;
            var writer = file.writerStreaming(self.io, &buffer);
            try writer.interface.writeAll(bytes[0..valid_end]);
            try writer.interface.flush();
            if (self.options.durability == .fsync_every_write) try file.sync(self.io);
        }
    }
};

fn hashCore(allocator: std.mem.Allocator, prev_hash: [32]u8, core: Core) ![32]u8 {
    const encoded = try memorypack.encode(allocator, core);
    defer allocator.free(encoded);
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(&prev_hash);
    hash.update(encoded);
    var digest: [32]u8 = undefined;
    hash.final(&digest);
    return digest;
}

fn broken(allocator: std.mem.Allocator, entries: usize, seq: i64, reason: []const u8) !VerifyResult {
    return .{ .intact = false, .entries = entries, .broken_seq = seq, .reason = .{ .bytes = try allocator.dupe(u8, reason) } };
}

fn cloneEntry(allocator: std.mem.Allocator, entry: Entry) !Entry {
    return .{
        .seq = entry.seq,
        .timestamp = entry.timestamp,
        .actor = .{ .bytes = try allocator.dupe(u8, entry.actor.bytes) },
        .action = .{ .bytes = try allocator.dupe(u8, entry.action.bytes) },
        .resource = .{ .bytes = try allocator.dupe(u8, entry.resource.bytes) },
        .detail = .{ .bytes = try allocator.dupe(u8, entry.detail.bytes) },
        .prev_hash = entry.prev_hash,
        .entry_hash = entry.entry_hash,
    };
}

fn deinitEntry(allocator: std.mem.Allocator, entry: *Entry) void {
    allocator.free(entry.actor.bytes);
    allocator.free(entry.action.bytes);
    allocator.free(entry.resource.bytes);
    allocator.free(entry.detail.bytes);
}

fn validText(value: []const u8) bool {
    return value.len > 0 and value.len <= 64 * 1024;
}

fn freeEntries(allocator: std.mem.Allocator, entries: []Entry) void {
    for (entries) |*entry| deinitEntry(allocator, entry);
    allocator.free(entries);
}

test "audit append, recovery, and intact verification" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    const dir = "zig-cache/audit-recovery";
    std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    var store = try Store.open(io, allocator, .{ .data_dir = dir });
    try std.testing.expectEqual(@as(i64, 0), try store.append(.{ .actor = .{ .bytes = "alice" }, .action = .{ .bytes = "login" }, .resource = .{ .bytes = "portal" }, .detail = .{ .bytes = "success" } }));
    try std.testing.expectEqual(@as(i64, 1), try store.append(.{ .actor = .{ .bytes = "bob" }, .action = .{ .bytes = "read" }, .resource = .{ .bytes = "report" }, .detail = .{ .bytes = "quarterly" } }));
    store.deinit();
    var reopened = try Store.open(io, allocator, .{ .data_dir = dir });
    defer reopened.deinit();
    const result = try reopened.verify();
    defer allocator.free(result.reason.bytes);
    try std.testing.expect(result.intact);
    try std.testing.expectEqual(@as(usize, 2), result.entries);
    const stats_result = try reopened.stats();
    try std.testing.expectEqual(@as(i64, 2), stats_result.next_seq);
}

test "audit verification detects tampered field, deletion, and reorder" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    const dir = "zig-cache/audit-tamper";
    std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    var store = try Store.open(io, allocator, .{ .data_dir = dir });
    for (0..3) |index| {
        _ = try store.append(.{ .actor = .{ .bytes = "alice" }, .action = .{ .bytes = "access" }, .resource = .{ .bytes = if (index == 1) "sensitive" else "public" }, .detail = .{ .bytes = "allowed" } });
    }
    store.deinit();
    try rewritePayload(io, allocator, dir, .tamper_field);
    var tampered = try Store.open(io, allocator, .{ .data_dir = dir });
    var result = try tampered.verify();
    try std.testing.expect(!result.intact);
    try std.testing.expectEqual(@as(i64, 1), result.broken_seq);
    allocator.free(result.reason.bytes);
    tampered.deinit();

    try rewritePayload(io, allocator, dir, .delete_middle);
    var deleted = try Store.open(io, allocator, .{ .data_dir = dir });
    result = try deleted.verify();
    try std.testing.expect(!result.intact);
    allocator.free(result.reason.bytes);
    deleted.deinit();

    try rewritePayload(io, allocator, dir, .reorder);
    var reordered = try Store.open(io, allocator, .{ .data_dir = dir });
    result = try reordered.verify();
    try std.testing.expect(!result.intact);
    allocator.free(result.reason.bytes);
    reordered.deinit();
}

const Rewrite = enum { tamper_field, delete_middle, reorder };

fn rewritePayload(io: std.Io, allocator: std.mem.Allocator, dir: []const u8, mode: Rewrite) !void {
    const path = try std.fmt.allocPrint(allocator, "{s}/audit.log", .{dir});
    defer allocator.free(path);
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(16 * 1024 * 1024));
    defer allocator.free(bytes);
    var frames: std.ArrayList([]const u8) = .empty;
    defer frames.deinit(allocator);
    var position: usize = 0;
    while (position < bytes.len) {
        const length = std.mem.readInt(u32, bytes[position..][0..4], .little);
        const start = position + 8;
        try frames.append(allocator, bytes[start..][0..@intCast(length)]);
        position = start + length;
    }
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(allocator);
    for (frames.items, 0..) |payload, index| {
        if (mode == .delete_middle and index == 1) continue;
        const selected = if (mode == .reorder and index == 0) frames.items[1] else if (mode == .reorder and index == 1) frames.items[0] else payload;
        var mutable = try allocator.dupe(u8, selected);
        defer allocator.free(mutable);
        if (mode == .tamper_field and index == 1) mutable[mutable.len - 1] ^= 1;
        var header: [8]u8 = undefined;
        std.mem.writeInt(u32, header[0..4], @intCast(mutable.len), .little);
        std.mem.writeInt(u32, header[4..8], std.hash.Crc32.hash(mutable), .little);
        try output.appendSlice(allocator, &header);
        try output.appendSlice(allocator, mutable);
    }
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = output.items });
}

test "audit concurrent append preserves sequence count" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    const dir = "zig-cache/audit-concurrent";
    std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    var store = try Store.open(io, allocator, .{ .data_dir = dir });
    defer store.deinit();
    const Context = struct { store: *Store, failed: *std.atomic.Value(bool) };
    var failed = std.atomic.Value(bool).init(false);
    var context = Context{ .store = &store, .failed = &failed };
    const worker = struct {
        fn run(ctx: *Context) void {
            for (0..8) |_| {
                _ = ctx.store.append(.{ .actor = .{ .bytes = "worker" }, .action = .{ .bytes = "write" }, .resource = .{ .bytes = "audit" }, .detail = .{ .bytes = "ok" } }) catch {
                    ctx.failed.store(true, .release);
                    return;
                };
            }
        }
    }.run;
    var threads: [4]std.Thread = undefined;
    for (&threads) |*thread| thread.* = try std.Thread.spawn(.{}, worker, .{&context});
    for (threads) |thread| thread.join();
    try std.testing.expect(!failed.load(.acquire));
    try std.testing.expectEqual(@as(usize, 32), (try store.stats()).entries);
}

test "audit CRC and truncated tails preserve committed entries" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    const dir = "zig-cache/audit-tail";
    std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    var store = try Store.open(io, allocator, .{ .data_dir = dir });
    _ = try store.append(.{ .actor = .{ .bytes = "alice" }, .action = .{ .bytes = "login" }, .resource = .{ .bytes = "portal" }, .detail = .{ .bytes = "ok" } });
    store.deinit();
    const path = try std.fmt.allocPrint(allocator, "{s}/audit.log", .{dir});
    defer allocator.free(path);
    var file = try std.Io.Dir.cwd().openFile(io, path, .{ .mode = .read_write });
    var buffer: [16]u8 = undefined;
    var writer = file.writerStreaming(io, &buffer);
    const stat = try file.stat(io);
    try writer.seekTo(stat.size);
    try writer.interface.writeAll(&.{ 32, 0, 0, 0, 0, 0, 0, 0, 1 });
    try writer.interface.flush();
    file.close(io);
    var reopened = try Store.open(io, allocator, .{ .data_dir = dir });
    defer reopened.deinit();
    try std.testing.expectEqual(@as(usize, 1), (try reopened.stats()).entries);
}
