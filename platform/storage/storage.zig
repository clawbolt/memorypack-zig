const std = @import("std");
const memorypack = @import("memorypack");
const core = @import("core");

pub const Options = struct {
    data_dir: []const u8,
    fsync: bool = true,
    max_frame_size: usize = 16 * 1024 * 1024,
};

pub const KV = struct {
    pub const memorypack_version_tolerant = true;
    key: memorypack.Str,
    value: memorypack.Str,
};

const Snapshot = struct {
    pub const memorypack_version_tolerant = true;
    version: i64,
    records: []const KV,
};

const Mutation = union(enum) {
    put: KV,
    delete: memorypack.Str,
};

pub const Stats = struct {
    records: usize,
    wal_frames: usize,
    version: i64,
};

pub const Store = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    options: Options,
    dir: []u8,
    snapshot_path: []u8,
    wal_path: []u8,
    records: std.ArrayList(KV),
    wal_frames: usize = 0,
    version: i64 = 0,
    mutex: std.Io.Mutex = .init,
    closed: bool = false,

    /// Opens a durable key/value collection and replays its WAL.
    pub fn open(io: std.Io, allocator: std.mem.Allocator, options: Options) !Store {
        if (options.data_dir.len == 0) return error.InvalidConfig;
        std.Io.Dir.cwd().createDirPath(io, options.data_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
        const snapshot = try std.fmt.allocPrint(allocator, "{s}/snapshot.bin", .{options.data_dir});
        errdefer allocator.free(snapshot);
        const wal = try std.fmt.allocPrint(allocator, "{s}/wal.log", .{options.data_dir});
        errdefer allocator.free(wal);
        var store = Store{
            .allocator = allocator,
            .io = io,
            .options = options,
            .dir = try allocator.dupe(u8, options.data_dir),
            .snapshot_path = snapshot,
            .wal_path = wal,
            .records = .empty,
        };
        errdefer store.deinit();
        try store.loadSnapshot();
        try store.replayWal();
        return store;
    }

    /// Releases all resources and is safe to call repeatedly.
    pub fn deinit(self: *Store) void {
        self.mutex.lockUncancelable(self.io);
        if (self.closed) {
            self.mutex.unlock(self.io);
            return;
        }
        self.closed = true;
        for (self.records.items) |*record| deinitKv(self.allocator, record);
        self.records.deinit(self.allocator);
        self.allocator.free(self.dir);
        self.allocator.free(self.snapshot_path);
        self.allocator.free(self.wal_path);
        self.mutex.unlock(self.io);
    }

    /// Durably inserts or replaces a key.
    pub fn put(self: *Store, key: []const u8, value: []const u8) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.closed) return error.StoreClosed;
        if (key.len == 0 or key.len > 4096) return error.InvalidInput;
        var owned = KV{ .key = .{ .bytes = try self.allocator.dupe(u8, key) }, .value = .{ .bytes = try self.allocator.dupe(u8, value) } };
        errdefer deinitKv(self.allocator, &owned);
        try self.appendMutation(.{ .put = owned });
        if (self.find(key)) |record| {
            self.allocator.free(record.value.bytes);
            record.value.bytes = owned.value.bytes;
            self.allocator.free(owned.key.bytes);
        } else {
            try self.records.append(self.allocator, owned);
        }
        self.version += 1;
    }

    /// Gets a copied value for a key, or null when absent.
    pub fn get(self: *Store, key: []const u8) !?memorypack.Str {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.closed) return error.StoreClosed;
        const record = self.find(key) orelse return null;
        return .{ .bytes = try self.allocator.dupe(u8, record.value.bytes) };
    }

    /// Deletes a key durably; deleting an absent key is harmless.
    pub fn delete(self: *Store, key: []const u8) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.closed) return error.StoreClosed;
        if (self.findIndex(key)) |index| {
            try self.appendMutation(.{ .delete = .{ .bytes = key } });
            var removed = self.records.orderedRemove(index);
            deinitKv(self.allocator, &removed);
            self.version += 1;
        }
    }

    /// Returns copied records in insertion order.
    pub fn list(self: *Store) ![]KV {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.closed) return error.StoreClosed;
        var result: std.ArrayList(KV) = .empty;
        errdefer freeRecords(self.allocator, result.items);
        for (self.records.items) |record| try result.append(self.allocator, try cloneKv(self.allocator, record));
        return result.toOwnedSlice(self.allocator);
    }

    /// Writes a snapshot and truncates the WAL after the snapshot is durable.
    pub fn compact(self: *Store) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.closed) return error.StoreClosed;
        const temp = try std.fmt.allocPrint(self.allocator, "{s}.tmp", .{self.snapshot_path});
        defer self.allocator.free(temp);
        const snapshot = Snapshot{ .version = self.version, .records = self.records.items };
        const bytes = try memorypack.encode(self.allocator, snapshot);
        defer self.allocator.free(bytes);
        try std.Io.Dir.cwd().writeFile(self.io, .{ .sub_path = temp, .data = bytes });
        var file = try std.Io.Dir.cwd().openFile(self.io, temp, .{ .mode = .read_only });
        defer file.close(self.io);
        if (self.options.fsync) try file.sync(self.io);
        try std.Io.Dir.rename(std.Io.Dir.cwd(), temp, std.Io.Dir.cwd(), self.snapshot_path, self.io);
        var wal = try std.Io.Dir.cwd().createFile(self.io, self.wal_path, .{ .truncate = true });
        defer wal.close(self.io);
        if (self.options.fsync) try wal.sync(self.io);
        self.wal_frames = 0;
    }

    /// Returns collection and persistence counters.
    pub fn stats(self: *Store) !Stats {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.closed) return error.StoreClosed;
        return .{ .records = self.records.items.len, .wal_frames = self.wal_frames, .version = self.version };
    }

    fn appendMutation(self: *Store, mutation: Mutation) !void {
        var file = try std.Io.Dir.cwd().createFile(self.io, self.wal_path, .{ .truncate = false });
        defer file.close(self.io);
        try core.writeDiskFrame(&file, self.io, self.allocator, self.options.max_frame_size, mutation, self.options.fsync);
        self.wal_frames += 1;
    }

    fn loadSnapshot(self: *Store) !void {
        const bytes = std.Io.Dir.cwd().readFileAlloc(self.io, self.snapshot_path, self.allocator, .limited(256 * 1024 * 1024)) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
        defer self.allocator.free(bytes);
        var snapshot = memorypack.decode(Snapshot, self.allocator, bytes) catch return error.CorruptData;
        defer memorypack.deinit(Snapshot, self.allocator, &snapshot);
        self.version = snapshot.version;
        for (snapshot.records) |record| try self.records.append(self.allocator, try cloneKv(self.allocator, record));
    }

    fn replayWal(self: *Store) !void {
        const mutations = core.readDiskFrames(Mutation, self.io, self.allocator, self.wal_path, self.options.max_frame_size) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
        defer {
            for (mutations) |*mutation| memorypack.deinit(Mutation, self.allocator, mutation);
            self.allocator.free(mutations);
        }
        self.wal_frames = mutations.len;
        for (mutations) |mutation| switch (mutation) {
            .put => |record| {
                if (self.find(record.key.bytes)) |existing| {
                    self.allocator.free(existing.value.bytes);
                    existing.value.bytes = try self.allocator.dupe(u8, record.value.bytes);
                } else try self.records.append(self.allocator, try cloneKv(self.allocator, record));
                self.version += 1;
            },
            .delete => |key| if (self.findIndex(key.bytes)) |index| {
                var removed = self.records.orderedRemove(index);
                deinitKv(self.allocator, &removed);
                self.version += 1;
            },
        };
    }

    fn find(self: *Store, key: []const u8) ?*KV {
        for (self.records.items) |*record| if (std.mem.eql(u8, record.key.bytes, key)) return record;
        return null;
    }

    fn findIndex(self: *Store, key: []const u8) ?usize {
        for (self.records.items, 0..) |record, index| if (std.mem.eql(u8, record.key.bytes, key)) return index;
        return null;
    }
};

fn cloneKv(allocator: std.mem.Allocator, record: KV) !KV {
    return .{ .key = .{ .bytes = try allocator.dupe(u8, record.key.bytes) }, .value = .{ .bytes = try allocator.dupe(u8, record.value.bytes) } };
}

fn deinitKv(allocator: std.mem.Allocator, record: *KV) void {
    allocator.free(record.key.bytes);
    allocator.free(record.value.bytes);
}

fn freeRecords(allocator: std.mem.Allocator, records: []KV) void {
    for (records) |*record| deinitKv(allocator, record);
    allocator.free(records);
}

test "storage WAL recovery and compaction" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    const dir = "zig-cache/platform-storage";
    std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    var store = try Store.open(io, allocator, .{ .data_dir = dir });
    try store.put("device/1", "online");
    try store.put("reading/1", "22.5");
    store.deinit();
    var reopened = try Store.open(io, allocator, .{ .data_dir = dir });
    defer reopened.deinit();
    const value = (try reopened.get("device/1")).?;
    defer allocator.free(value.bytes);
    try std.testing.expectEqualStrings("online", value.bytes);
    try reopened.compact();
    try std.testing.expectEqual(@as(usize, 0), (try reopened.stats()).wal_frames);
}
