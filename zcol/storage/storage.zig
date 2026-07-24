const std = @import("std");
const memorypack = @import("memorypack");

pub const Error = error{
    InvalidConfig,
    InvalidSchema,
    InvalidChunk,
    TableClosed,
    ManifestMissing,
    ColumnNotFound,
};

pub const ColumnType = enum(u8) {
    i64,
    f64,
    bool,
    string,
};

pub const ColumnSchema = struct {
    pub const memorypack_version_tolerant = true;
    name: memorypack.Str,
    kind: ColumnType,
};

pub const ChunkMeta = struct {
    pub const memorypack_version_tolerant = true;
    id: u32,
    rows: u32,
};

pub const Manifest = struct {
    pub const memorypack_version_tolerant = true;
    version: u32,
    chunk_rows: u32,
    schema: []const ColumnSchema,
    chunks: []const ChunkMeta,
};

pub const Column = union(enum) {
    i64: []const i64,
    f64: []const f64,
    bool: []const bool,
    string: []const memorypack.Str,
};

pub const Chunk = struct {
    pub const memorypack_version_tolerant = true;
    columns: []const Column,
};

pub const Stats = struct {
    columns: usize,
    chunks: usize,
    rows: usize,
    bytes: u64,
};

pub const Table = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    dir: []u8,
    manifest_path: []u8,
    schema: std.ArrayList(ColumnSchema),
    chunks: std.ArrayList(ChunkMeta),
    chunk_rows: u32,
    next_chunk: u32 = 0,
    closed: bool = false,
    mutex: std.Io.Mutex = .init,

    pub fn create(
        io: std.Io,
        allocator: std.mem.Allocator,
        data_dir: []const u8,
        schema: []const ColumnSchema,
        chunk_rows: u32,
    ) !Table {
        if (data_dir.len == 0 or schema.len == 0 or chunk_rows == 0) return error.InvalidConfig;
        try std.Io.Dir.cwd().createDirPath(io, data_dir);
        var table = Table{
            .allocator = allocator,
            .io = io,
            .dir = try allocator.dupe(u8, data_dir),
            .manifest_path = try std.fmt.allocPrint(allocator, "{s}/manifest.bin", .{data_dir}),
            .schema = .empty,
            .chunks = .empty,
            .chunk_rows = chunk_rows,
        };
        errdefer table.deinit();
        try validateSchema(schema);
        for (schema) |column| try table.schema.append(allocator, .{
            .name = .{ .bytes = try allocator.dupe(u8, column.name.bytes) },
            .kind = column.kind,
        });
        try table.writeManifest();
        return table;
    }

    pub fn open(io: std.Io, allocator: std.mem.Allocator, data_dir: []const u8) !Table {
        if (data_dir.len == 0) return error.InvalidConfig;
        const manifest_path = try std.fmt.allocPrint(allocator, "{s}/manifest.bin", .{data_dir});
        errdefer allocator.free(manifest_path);
        const bytes = std.Io.Dir.cwd().readFileAlloc(io, manifest_path, allocator, .limited(256 * 1024 * 1024)) catch |err| switch (err) {
            error.FileNotFound => return error.ManifestMissing,
            else => return err,
        };
        defer allocator.free(bytes);
        var manifest = try memorypack.decode(Manifest, allocator, bytes);
        errdefer memorypack.deinit(Manifest, allocator, &manifest);
        try validateSchema(manifest.schema);
        if (manifest.chunk_rows == 0) return error.InvalidConfig;
        var table = Table{
            .allocator = allocator,
            .io = io,
            .dir = try allocator.dupe(u8, data_dir),
            .manifest_path = manifest_path,
            .schema = .empty,
            .chunks = .empty,
            .chunk_rows = manifest.chunk_rows,
            .next_chunk = @intCast(manifest.chunks.len),
        };
        errdefer table.deinit();
        for (manifest.schema) |column| try table.schema.append(allocator, .{
            .name = .{ .bytes = try allocator.dupe(u8, column.name.bytes) },
            .kind = column.kind,
        });
        for (manifest.chunks) |chunk| try table.chunks.append(allocator, chunk);
        for (manifest.schema) |column| allocator.free(column.name.bytes);
        allocator.free(manifest.schema);
        allocator.free(manifest.chunks);
        return table;
    }

    pub fn deinit(self: *Table) void {
        self.mutex.lockUncancelable(self.io);
        if (self.closed) {
            self.mutex.unlock(self.io);
            return;
        }
        self.closed = true;
        for (self.schema.items) |*column| self.allocator.free(column.name.bytes);
        self.schema.deinit(self.allocator);
        self.chunks.deinit(self.allocator);
        self.allocator.free(self.dir);
        self.allocator.free(self.manifest_path);
        self.mutex.unlock(self.io);
    }

    pub fn getSchema(self: *Table) ![]const ColumnSchema {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.closed) return error.TableClosed;
        return self.schema.items;
    }

    pub fn appendChunk(self: *Table, columns: []const Column) !u32 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.closed) return error.TableClosed;
        const rows = try validateColumns(self.schema.items, columns);
        if (rows == 0 or rows > self.chunk_rows) return error.InvalidChunk;
        const id = self.next_chunk;
        const chunk = Chunk{ .columns = columns };
        const bytes = try memorypack.encode(self.allocator, chunk);
        defer self.allocator.free(bytes);
        const path = try self.chunkPath(id);
        defer self.allocator.free(path);
        const temp = try std.fmt.allocPrint(self.allocator, "{s}.tmp", .{path});
        defer self.allocator.free(temp);
        try std.Io.Dir.cwd().writeFile(self.io, .{ .sub_path = temp, .data = bytes });
        var file = try std.Io.Dir.cwd().openFile(self.io, temp, .{ .mode = .read_only });
        defer file.close(self.io);
        try file.sync(self.io);
        try std.Io.Dir.rename(std.Io.Dir.cwd(), temp, std.Io.Dir.cwd(), path, self.io);
        try self.chunks.append(self.allocator, .{ .id = id, .rows = @intCast(rows) });
        self.next_chunk += 1;
        try self.writeManifest();
        return id;
    }

    pub fn readChunk(self: *Table, id: u32) !Chunk {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.closed) return error.TableClosed;
        const path = try self.chunkPath(id);
        defer self.allocator.free(path);
        const bytes = try std.Io.Dir.cwd().readFileAlloc(self.io, path, self.allocator, .limited(256 * 1024 * 1024));
        defer self.allocator.free(bytes);
        return memorypack.decode(Chunk, self.allocator, bytes);
    }

    pub fn stats(self: *Table) !Stats {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.closed) return error.TableClosed;
        var rows: usize = 0;
        for (self.chunks.items) |chunk| rows += chunk.rows;
        var bytes: u64 = 0;
        for (self.chunks.items) |chunk| {
            const path = try self.chunkPath(chunk.id);
            defer self.allocator.free(path);
            const file = std.Io.Dir.cwd().openFile(self.io, path, .{ .mode = .read_only }) catch continue;
            defer file.close(self.io);
            bytes += (try file.stat(self.io)).size;
        }
        return .{ .columns = self.schema.items.len, .chunks = self.chunks.items.len, .rows = rows, .bytes = bytes };
    }

    fn chunkPath(self: *Table, id: u32) ![]u8 {
        return std.fmt.allocPrint(self.allocator, "{s}/chunk-{d}.bin", .{ self.dir, id });
    }

    fn writeManifest(self: *Table) !void {
        const manifest = Manifest{
            .version = 1,
            .chunk_rows = self.chunk_rows,
            .schema = self.schema.items,
            .chunks = self.chunks.items,
        };
        const bytes = try memorypack.encode(self.allocator, manifest);
        defer self.allocator.free(bytes);
        const temp = try std.fmt.allocPrint(self.allocator, "{s}.tmp", .{self.manifest_path});
        defer self.allocator.free(temp);
        try std.Io.Dir.cwd().writeFile(self.io, .{ .sub_path = temp, .data = bytes });
        var file = try std.Io.Dir.cwd().openFile(self.io, temp, .{ .mode = .read_only });
        defer file.close(self.io);
        try file.sync(self.io);
        try std.Io.Dir.rename(std.Io.Dir.cwd(), temp, std.Io.Dir.cwd(), self.manifest_path, self.io);
    }
};

fn validateSchema(schema: []const ColumnSchema) !void {
    if (schema.len == 0) return error.InvalidSchema;
    for (schema, 0..) |column, index| {
        if (column.name.bytes.len == 0) return error.InvalidSchema;
        for (schema[0..index]) |previous| if (std.mem.eql(u8, previous.name.bytes, column.name.bytes)) return error.InvalidSchema;
    }
}

fn validateColumns(schema: []const ColumnSchema, columns: []const Column) !usize {
    if (schema.len != columns.len) return error.InvalidChunk;
    var rows: ?usize = null;
    for (schema, columns) |expected, column| {
        const count = switch (column) {
            .i64 => |values| if (expected.kind == .i64) values.len else return error.InvalidChunk,
            .f64 => |values| if (expected.kind == .f64) values.len else return error.InvalidChunk,
            .bool => |values| if (expected.kind == .bool) values.len else return error.InvalidChunk,
            .string => |values| if (expected.kind == .string) values.len else return error.InvalidChunk,
        };
        if (rows) |known| {
            if (known != count) return error.InvalidChunk;
        } else rows = count;
    }
    return rows orelse error.InvalidChunk;
}

pub fn freeChunk(allocator: std.mem.Allocator, chunk: *Chunk) void {
    for (chunk.columns) |column| switch (column) {
        .i64 => |values| allocator.free(values),
        .f64 => |values| allocator.free(values),
        .bool => |values| allocator.free(values),
        .string => |values| {
            for (values) |value| allocator.free(value.bytes);
            allocator.free(values);
        },
    };
    allocator.free(chunk.columns);
}

test "column table persists manifest and typed chunks" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    const dir = "zig-cache/zcol-storage";
    std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    const schema = [_]ColumnSchema{
        .{ .name = .{ .bytes = "id" }, .kind = .i64 },
        .{ .name = .{ .bytes = "score" }, .kind = .f64 },
        .{ .name = .{ .bytes = "active" }, .kind = .bool },
        .{ .name = .{ .bytes = "team" }, .kind = .string },
    };
    var table = try Table.create(io, allocator, dir, &schema, 2);
    defer table.deinit();
    const teams = [_]memorypack.Str{ .{ .bytes = "a" }, .{ .bytes = "b" } };
    _ = try table.appendChunk(&.{
        .{ .i64 = &.{ 1, 2 } },
        .{ .f64 = &.{ 1.5, 2.5 } },
        .{ .bool = &.{ true, false } },
        .{ .string = &teams },
    });
    var reopened = try Table.open(io, allocator, dir);
    defer reopened.deinit();
    const stats_value = try reopened.stats();
    try std.testing.expectEqual(@as(usize, 2), stats_value.rows);
    var chunk = try reopened.readChunk(0);
    defer freeChunk(allocator, &chunk);
    try std.testing.expectEqual(@as(usize, 2), chunk.columns[0].i64.len);
    try std.testing.expectEqualStrings("b", chunk.columns[3].string[1].bytes);
}
