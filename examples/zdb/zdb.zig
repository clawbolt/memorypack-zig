const std = @import("std");
const builtin = @import("builtin");
const memorypack = @import("memorypack");

pub const Status = enum(u8) {
    draft = 0,
    active = 1,
    archived = 2,
};

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

const max_frame_size = 16 * 1024 * 1024;

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

    pub fn open(io: std.Io, allocator: std.mem.Allocator, directory: []const u8) !Store {
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
        };
        errdefer store.deinit();
        try store.loadSnapshot();
        try store.replayWal();
        return store;
    }

    pub fn deinit(self: *Store) void {
        var iterator = self.documents.valueIterator();
        while (iterator.next()) |document| deinitDocument(self.allocator, document);
        self.documents.deinit();
        for (&self.status_index) |*ids| ids.deinit(self.allocator);
        self.allocator.free(self.directory);
        self.allocator.free(self.snapshot_path);
        self.allocator.free(self.snapshot_temp_path);
        self.allocator.free(self.wal_path);
        self.* = undefined;
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
            if (length > max_frame_size or length > bytes.len - position) {
                truncated = true;
                break;
            }
            const payload = bytes[position..][0..@intCast(length)];
            position += payload.len;
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
        if (payload.items.len > std.math.maxInt(u32)) return error.FrameTooLarge;
        var file = try std.Io.Dir.cwd().createFile(self.io, self.wal_path, .{ .truncate = false });
        defer file.close(self.io);
        const size = try file.stat(self.io);
        var buffer: [4096]u8 = undefined;
        var writer = file.writerStreaming(self.io, &buffer);
        try writer.seekTo(size.size);
        var length: [4]u8 = undefined;
        std.mem.writeInt(u32, &length, @intCast(payload.items.len), .little);
        try writer.interface.writeAll(&length);
        try writer.interface.writeAll(payload.items);
        try writer.interface.flush();
        try file.sync(self.io);
    }

    pub fn put(self: *Store, document: Document) !void {
        try self.appendMutation(.{ .put = .{ .document = document } });
        try self.applyMutation(.{ .put = .{ .document = document } });
        self.wal_frames += 1;
    }

    pub fn delete(self: *Store, id: i32) !void {
        try self.appendMutation(.{ .delete = .{ .id = id } });
        self.applyDelete(id);
        self.wal_frames += 1;
    }

    pub fn get(self: *Store, id: i32) ?Document {
        return self.documents.get(id);
    }

    pub fn compact(self: *Store) !void {
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
        try std.Io.Dir.cwd().writeFile(self.io, .{
            .sub_path = self.wal_path,
            .data = &.{},
        });
        self.snapshot_version += 1;
        self.wal_frames = 0;
    }

    pub fn queryStatus(self: *Store, status: Status, output: *std.ArrayList(i32)) !void {
        try output.appendSlice(self.allocator, self.status_index[@intFromEnum(status)].items);
    }

    pub fn count(self: *Store) usize {
        return self.documents.count();
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
