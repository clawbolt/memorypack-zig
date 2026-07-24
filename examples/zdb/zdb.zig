const std = @import("std");
const builtin = @import("builtin");
const memorypack = @import("memorypack");

pub const Status = enum(u8) {
    draft = 0,
    active = 1,
    archived = 2,
};

pub const Durability = enum {
    fsync_every_write,
    buffered,
};

pub const Options = struct {
    durability: Durability = .fsync_every_write,
    auto_compact_wal_frames: usize = 0,
    max_frame_size: usize = 16 * 1024 * 1024,
};

pub const Error = error{
    StoreClosed,
    CorruptSnapshot,
    FrameTooLarge,
    InvalidWalChecksum,
    QueryLimitTooLarge,
} || std.mem.Allocator.Error;

pub const Document = struct {
    pub const memorypack_version_tolerant = true;

    id: i32,
    name: memorypack.Str,
    status: Status,
    score: i64,
    due: ?i32,
    tags: []const memorypack.Str,
};

pub const MutationTag = enum(u16) {
    put = 0,
    delete = 1,
};

pub const Put = struct {
    document: Document,
};

pub const Delete = struct {
    id: i32,
};

pub const Mutation = union(MutationTag) {
    put: Put,
    delete: Delete,
};

const Snapshot = struct {
    pub const memorypack_version_tolerant = true;

    version: i64,
    documents: []const Document,
};

const Sink = struct {
    list: *std.ArrayList(u8),
    allocator: std.mem.Allocator,

    pub fn writeAll(self: Sink, bytes: []const u8) !void {
        try self.list.appendSlice(self.allocator, bytes);
    }
};

const FrameReader = struct {
    bytes: []const u8,
    pos: usize = 0,

    pub fn read(self: *FrameReader, destination: []u8) !usize {
        if (self.pos == self.bytes.len) return 0;
        const count = @min(@min(destination.len, 2), self.bytes.len - self.pos);
        @memcpy(destination[0..count], self.bytes[self.pos..][0..count]);
        self.pos += count;
        return count;
    }
};

pub const Store = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    directory: []u8,
    snapshot_path: []u8,
    snapshot_temp_path: []u8,
    wal_path: []u8,
    documents: std.AutoHashMap(i32, Document),
    status_index: [3]std.ArrayList(i32),
    snapshot_version: i64 = 0,
    wal_frames: usize = 0,
    options: Options,
    mutex: std.Io.Mutex = .init,
    closed: bool = false,

    /// Opens or creates a store directory and recovers its snapshot and WAL.
    pub fn open(io: std.Io, allocator: std.mem.Allocator, directory: []const u8) !Store {
        return openWithOptions(io, allocator, directory, .{});
    }

    /// Opens a store with explicit durability, compaction, and frame limits.
    pub fn openWithOptions(
        io: std.Io,
        allocator: std.mem.Allocator,
        directory: []const u8,
        options: Options,
    ) !Store {
        std.Io.Dir.cwd().createDirPath(io, directory) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
        var store = Store{
            .allocator = allocator,
            .io = io,
            .directory = try allocator.dupe(u8, directory),
            .snapshot_path = try std.fmt.allocPrint(allocator, "{s}/snapshot.bin", .{directory}),
            .snapshot_temp_path = try std.fmt.allocPrint(allocator, "{s}/snapshot.tmp", .{directory}),
            .wal_path = try std.fmt.allocPrint(allocator, "{s}/wal.bin", .{directory}),
            .documents = std.AutoHashMap(i32, Document).init(allocator),
            .status_index = .{ .empty, .empty, .empty },
            .options = options,
        };
        errdefer store.deinit();
        try store.loadSnapshot();
        try store.replayWal();
        return store;
    }

    /// Closes the store and releases owned memory. Calling close twice is safe.
    pub fn close(self: *Store) void {
        self.mutex.lockUncancelable(self.io);
        if (self.closed) {
            self.mutex.unlock(self.io);
            return;
        }
        self.closed = true;
        var iterator = self.documents.valueIterator();
        while (iterator.next()) |document| deinitDocument(self.allocator, document);
        self.documents.deinit();
        for (&self.status_index) |*ids| ids.deinit(self.allocator);
        self.allocator.free(self.directory);
        self.allocator.free(self.snapshot_path);
        self.allocator.free(self.snapshot_temp_path);
        self.allocator.free(self.wal_path);
        self.mutex.unlock(self.io);
    }

    /// Alias for close, suitable for defer.
    pub fn deinit(self: *Store) void {
        self.close();
    }

    fn loadSnapshot(self: *Store) !void {
        const bytes = readFile(self.io, self.allocator, self.snapshot_path) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
        defer self.allocator.free(bytes);
        var snapshot = try memorypack.decode(Snapshot, self.allocator, bytes);
        defer memorypack.deinit(Snapshot, self.allocator, &snapshot);
        self.snapshot_version = snapshot.version;
        for (snapshot.documents) |document| {
            try self.insertOwned(try cloneDocument(self.allocator, document));
        }
    }

    fn replayWal(self: *Store) !void {
        const bytes = readFile(self.io, self.allocator, self.wal_path) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
        defer self.allocator.free(bytes);
        var position: usize = 0;
        var truncated = false;
        while (position < bytes.len) {
            if (bytes.len - position < 4) {
                truncated = true;
                break;
            }
            const length = std.mem.readInt(u32, bytes[position..][0..4], .little);
            position += 4;
            if (length > self.options.max_frame_size or length > bytes.len - position) {
                truncated = true;
                break;
            }
            if (bytes.len - position < 4 + length) {
                truncated = true;
                break;
            }
            const expected_crc = std.mem.readInt(u32, bytes[position..][0..4], .little);
            position += 4;
            const payload = bytes[position..][0..@intCast(length)];
            position += payload.len;
            if (std.hash.Crc32.hash(payload) != expected_crc) {
                truncated = true;
                break;
            }
            var reader = FrameReader{ .bytes = payload };
            var mutation = memorypack.decodeFromReader(Mutation, self.allocator, &reader) catch break;
            defer memorypack.deinit(Mutation, self.allocator, &mutation);
            try self.applyMutation(mutation);
            self.wal_frames += 1;
        }
        if (truncated and !builtin.is_test) {
            std.debug.print("Warning: ignored truncated final WAL frame.\n", .{});
        }
    }

    fn insertOwned(self: *Store, document: Document) !void {
        try self.documents.put(document.id, document);
        try self.status_index[@intFromEnum(document.status)].append(self.allocator, document.id);
    }

    fn removeIndex(self: *Store, document: Document) void {
        const ids = &self.status_index[@intFromEnum(document.status)];
        for (ids.items, 0..) |id, index| {
            if (id == document.id) {
                _ = ids.orderedRemove(index);
                return;
            }
        }
    }

    fn applyPut(self: *Store, document: Document) !void {
        if (self.documents.fetchRemove(document.id)) |removed| {
            var removed_document = removed.value;
            self.removeIndex(removed_document);
            deinitDocument(self.allocator, &removed_document);
        }
        try self.insertOwned(try cloneDocument(self.allocator, document));
    }

    fn applyDelete(self: *Store, id: i32) void {
        if (self.documents.fetchRemove(id)) |removed| {
            var removed_document = removed.value;
            self.removeIndex(removed_document);
            deinitDocument(self.allocator, &removed_document);
        }
    }

    fn applyMutation(self: *Store, mutation: Mutation) !void {
        switch (mutation) {
            .put => |operation| try self.applyPut(operation.document),
            .delete => |operation| self.applyDelete(operation.id),
        }
    }

    fn appendMutation(self: *Store, mutation: Mutation) !void {
        var payload: std.ArrayList(u8) = .empty;
        defer payload.deinit(self.allocator);
        try memorypack.encodeTo(self.allocator, mutation, Sink{
            .list = &payload,
            .allocator = self.allocator,
        });
        if (payload.items.len > self.options.max_frame_size or payload.items.len > std.math.maxInt(u32)) {
            return error.FrameTooLarge;
        }
        var file = try std.Io.Dir.cwd().createFile(self.io, self.wal_path, .{ .truncate = false });
        defer file.close(self.io);
        const size = try file.stat(self.io);
        var buffer: [4096]u8 = undefined;
        var writer = file.writerStreaming(self.io, &buffer);
        try writer.seekTo(size.size);
        var length: [4]u8 = undefined;
        std.mem.writeInt(u32, &length, @intCast(payload.items.len), .little);
        var checksum: [4]u8 = undefined;
        std.mem.writeInt(u32, &checksum, std.hash.Crc32.hash(payload.items), .little);
        try writer.interface.writeAll(&length);
        try writer.interface.writeAll(&checksum);
        try writer.interface.writeAll(payload.items);
        try writer.interface.flush();
        if (self.options.durability == .fsync_every_write) try file.sync(self.io);
    }

    /// Durably appends or replaces a document.
    pub fn put(self: *Store, document: Document) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.closed) return error.StoreClosed;
        try self.appendMutation(.{ .put = .{ .document = document } });
        try self.applyMutation(.{ .put = .{ .document = document } });
        self.wal_frames += 1;
        if (self.options.auto_compact_wal_frames != 0 and
            self.wal_frames >= self.options.auto_compact_wal_frames) try self.compactLocked();
    }

    /// Durably appends a delete operation for an ID.
    pub fn delete(self: *Store, id: i32) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.closed) return error.StoreClosed;
        try self.appendMutation(.{ .delete = .{ .id = id } });
        self.applyDelete(id);
        self.wal_frames += 1;
        if (self.options.auto_compact_wal_frames != 0 and
            self.wal_frames >= self.options.auto_compact_wal_frames) try self.compactLocked();
    }

    /// Looks up a document, returning null when the ID is absent.
    pub fn get(self: *Store, id: i32) ?Document {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.closed) return null;
        return self.documents.get(id);
    }

    /// Atomically checkpoints current state and clears the durable WAL.
    pub fn compact(self: *Store) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.closed) return error.StoreClosed;
        return self.compactLocked();
    }

    fn compactLocked(self: *Store) !void {
        const documents = try self.allocator.alloc(Document, self.documents.count());
        defer self.allocator.free(documents);
        var iterator = self.documents.valueIterator();
        var index: usize = 0;
        while (iterator.next()) |document| {
            documents[index] = document.*;
            index += 1;
        }
        const snapshot = Snapshot{
            .version = self.snapshot_version + 1,
            .documents = documents,
        };
        const bytes = try memorypack.encode(self.allocator, snapshot);
        defer self.allocator.free(bytes);
        try std.Io.Dir.cwd().writeFile(self.io, .{
            .sub_path = self.snapshot_temp_path,
            .data = bytes,
        });
        var snapshot_file = try std.Io.Dir.cwd().openFile(self.io, self.snapshot_temp_path, .{ .mode = .read_only });
        defer snapshot_file.close(self.io);
        try snapshot_file.sync(self.io);
        try std.Io.Dir.rename(
            std.Io.Dir.cwd(),
            self.snapshot_temp_path,
            std.Io.Dir.cwd(),
            self.snapshot_path,
            self.io,
        );
        var wal_file = try std.Io.Dir.cwd().createFile(self.io, self.wal_path, .{ .truncate = true });
        defer wal_file.close(self.io);
        if (self.options.durability == .fsync_every_write) try wal_file.sync(self.io);
        self.snapshot_version += 1;
        self.wal_frames = 0;
    }

    /// Appends all IDs in a status index to a caller-owned list.
    pub fn queryStatus(self: *Store, status: Status, output: *std.ArrayList(i32)) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.closed) return error.StoreClosed;
        try output.appendSlice(self.allocator, self.status_index[@intFromEnum(status)].items);
    }

    /// Returns a bounded, paginated copy of IDs from the status index.
    pub fn queryStatusPage(
        self: *Store,
        allocator: std.mem.Allocator,
        status: Status,
        offset: usize,
        limit: usize,
    ) ![]i32 {
        if (limit > 1_000_000) return error.QueryLimitTooLarge;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.closed) return error.StoreClosed;
        const ids = self.status_index[@intFromEnum(status)].items;
        const start = @min(offset, ids.len);
        const end = @min(start +| limit, ids.len);
        return allocator.dupe(i32, ids[start..end]);
    }

    /// Returns the current number of materialized documents.
    pub fn count(self: *Store) usize {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.closed) return 0;
        return self.documents.count();
    }

    /// Returns stable ascending IDs for a bounded page of the collection.
    pub fn listIds(self: *Store, allocator: std.mem.Allocator, offset: usize, limit: usize) ![]i32 {
        if (limit > 1_000_000) return error.QueryLimitTooLarge;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.closed) return error.StoreClosed;
        var ids: std.ArrayList(i32) = .empty;
        errdefer ids.deinit(allocator);
        var iterator = self.documents.keyIterator();
        while (iterator.next()) |id| try ids.append(allocator, id.*);
        for (ids.items, 0..) |*id, index| {
            for (ids.items[index + 1 ..]) |*other| {
                if (other.* < id.*) std.mem.swap(i32, id, other);
            }
        }
        const start = @min(offset, ids.items.len);
        const end = @min(start +| limit, ids.items.len);
        const result = try allocator.dupe(i32, ids.items[start..end]);
        ids.deinit(allocator);
        return result;
    }
};

pub fn cloneDocument(allocator: std.mem.Allocator, source: Document) !Document {
    const title = try allocator.dupe(u8, source.name.bytes);
    errdefer allocator.free(title);
    const tags = try allocator.alloc(memorypack.Str, source.tags.len);
    errdefer {
        for (tags) |tag| allocator.free(tag.bytes);
        allocator.free(tags);
    }
    for (tags, source.tags) |*destination, tag| {
        destination.* = .{ .bytes = try allocator.dupe(u8, tag.bytes) };
    }
    return .{
        .id = source.id,
        .name = .{ .bytes = title },
        .status = source.status,
        .score = source.score,
        .due = source.due,
        .tags = tags,
    };
}

pub fn deinitDocument(allocator: std.mem.Allocator, document: *Document) void {
    allocator.free(document.name.bytes);
    for (document.tags) |tag| allocator.free(tag.bytes);
    allocator.free(document.tags);
    document.* = undefined;
}

fn readFile(io: std.Io, allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(64 * 1024 * 1024));
}

test "WAL append and replay rebuilds state" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const directory = "zig-cache/zdb-test-wal";
    std.Io.Dir.cwd().deleteTree(io, directory) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, directory) catch {};
    var store = try Store.open(io, allocator, directory);
    try store.put(.{
        .id = 1,
        .name = .{ .bytes = "Ada" },
        .status = .active,
        .score = 42,
        .due = null,
        .tags = &.{.{ .bytes = "admin" }},
    });
    store.deinit();
    var reopened = try Store.open(io, allocator, directory);
    defer reopened.deinit();
    try std.testing.expectEqual(@as(usize, 1), reopened.count());
    try std.testing.expectEqual(@as(i64, 42), reopened.get(1).?.score);
}

test "snapshot compaction preserves state and clears WAL" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const directory = "zig-cache/zdb-test-compact";
    std.Io.Dir.cwd().deleteTree(io, directory) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, directory) catch {};
    var store = try Store.open(io, allocator, directory);
    defer store.deinit();
    for (0..5) |i| try store.put(.{
        .id = @intCast(i),
        .name = .{ .bytes = "document" },
        .status = .draft,
        .score = @intCast(i),
        .due = @intCast(i),
        .tags = &.{},
    });
    try std.testing.expect(store.wal_frames == 5);
    try store.compact();
    try std.testing.expectEqual(@as(usize, 0), store.wal_frames);
    var wal = try std.Io.Dir.cwd().openFile(io, "zig-cache/zdb-test-compact/wal.bin", .{ .mode = .read_only });
    defer wal.close(io);
    try std.testing.expectEqual(@as(u64, 0), (try wal.stat(io)).size);
    try store.put(.{
        .id = 99,
        .name = .{ .bytes = "after-checkpoint" },
        .status = .active,
        .score = 99,
        .due = null,
        .tags = &.{},
    });
    var reopened = try Store.open(io, allocator, directory);
    defer reopened.deinit();
    try std.testing.expectEqual(@as(usize, 6), reopened.count());
    try std.testing.expectEqual(@as(usize, 1), reopened.wal_frames);
}

test "truncated final WAL frame is ignored" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const directory = "zig-cache/zdb-test-truncated";
    std.Io.Dir.cwd().deleteTree(io, directory) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, directory) catch {};
    var store = try Store.open(io, allocator, directory);
    try store.put(.{
        .id = 7,
        .name = .{ .bytes = "safe" },
        .status = .active,
        .score = 1,
        .due = null,
        .tags = &.{},
    });
    store.deinit();
    var file = try std.Io.Dir.cwd().openFile(io, "zig-cache/zdb-test-truncated/wal.bin", .{ .mode = .read_write });
    const stat = try file.stat(io);
    var writer_buffer: [16]u8 = undefined;
    var writer = file.writerStreaming(io, &writer_buffer);
    try writer.seekTo(stat.size);
    try writer.interface.writeAll(&.{ 200, 0, 0, 0, 1, 2 });
    try writer.interface.flush();
    file.close(io);
    var reopened = try Store.open(io, allocator, directory);
    defer reopened.deinit();
    try std.testing.expectEqual(@as(usize, 1), reopened.count());
}

test "bad WAL checksum stops recovery before the corrupt record" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const directory = "zig-cache/zdb-test-crc";
    std.Io.Dir.cwd().deleteTree(io, directory) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, directory) catch {};
    var store = try Store.open(io, allocator, directory);
    try store.put(.{ .id = 1, .name = .{ .bytes = "good" }, .status = .active, .score = 1, .due = null, .tags = &.{} });
    try store.put(.{ .id = 2, .name = .{ .bytes = "corrupt" }, .status = .active, .score = 2, .due = null, .tags = &.{} });
    store.deinit();

    const wal_path = "zig-cache/zdb-test-crc/wal.bin";
    var bytes = try readFile(io, allocator, wal_path);
    defer allocator.free(bytes);
    bytes[bytes.len - 1] ^= 0x80;
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = wal_path, .data = bytes });
    var reopened = try Store.open(io, allocator, directory);
    defer reopened.deinit();
    try std.testing.expectEqual(@as(usize, 1), reopened.count());
    try std.testing.expect(reopened.get(1) != null);
    try std.testing.expect(reopened.get(2) == null);
}

test "pagination returns stable bounded slices" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const directory = "zig-cache/zdb-test-page";
    std.Io.Dir.cwd().deleteTree(io, directory) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, directory) catch {};
    var store = try Store.open(io, allocator, directory);
    defer store.deinit();
    for (1..6) |id| try store.put(.{
        .id = @intCast(id),
        .name = .{ .bytes = "page" },
        .status = .active,
        .score = 0,
        .due = null,
        .tags = &.{},
    });
    const ids = try store.listIds(allocator, 2, 2);
    defer allocator.free(ids);
    try std.testing.expectEqualSlices(i32, &.{ 3, 4 }, ids);
}

const ConcurrentContext = struct {
    store: *Store,
    failed: *std.atomic.Value(bool),
};

fn concurrentPut(context: *ConcurrentContext, first_id: i32) void {
    for (0..8) |offset| {
        context.store.put(.{
            .id = first_id + @as(i32, @intCast(offset)),
            .name = .{ .bytes = "thread" },
            .status = .active,
            .score = 1,
            .due = null,
            .tags = &.{},
        }) catch {
            context.failed.store(true, .release);
            return;
        };
    }
}

test "concurrent puts remain consistent under the store mutex" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const directory = "zig-cache/zdb-test-concurrent";
    std.Io.Dir.cwd().deleteTree(io, directory) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, directory) catch {};
    var store = try Store.open(io, allocator, directory);
    defer store.deinit();
    var failed = std.atomic.Value(bool).init(false);
    var context = ConcurrentContext{ .store = &store, .failed = &failed };
    var threads: [4]std.Thread = undefined;
    for (&threads, 0..) |*thread, index| {
        thread.* = try std.Thread.spawn(.{}, concurrentPut, .{ &context, @as(i32, @intCast(index * 8 + 1)) });
    }
    for (threads) |thread| thread.join();
    try std.testing.expect(!failed.load(.acquire));
    try std.testing.expectEqual(@as(usize, 32), store.count());
}

test "status index tracks puts, updates, and deletes" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const directory = "zig-cache/zdb-test-index";
    std.Io.Dir.cwd().deleteTree(io, directory) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, directory) catch {};
    var store = try Store.open(io, allocator, directory);
    defer store.deinit();
    try store.put(.{ .id = 1, .name = .{ .bytes = "one" }, .status = .active, .score = 0, .due = null, .tags = &.{} });
    try store.put(.{ .id = 2, .name = .{ .bytes = "two" }, .status = .draft, .score = 0, .due = null, .tags = &.{} });
    try store.put(.{ .id = 1, .name = .{ .bytes = "one" }, .status = .archived, .score = 0, .due = null, .tags = &.{} });
    var ids: std.ArrayList(i32) = .empty;
    defer ids.deinit(allocator);
    try store.queryStatus(.archived, &ids);
    try std.testing.expectEqualSlices(i32, &.{1}, ids.items);
    try store.delete(1);
    ids.clearRetainingCapacity();
    try store.queryStatus(.archived, &ids);
    try std.testing.expectEqual(@as(usize, 0), ids.items.len);
}
