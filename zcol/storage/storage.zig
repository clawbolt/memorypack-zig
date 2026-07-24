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
    zone_maps: []const ZoneMap = &.{},
};
pub const ZoneMap = struct {
    pub const memorypack_version_tolerant = true;
    min: memorypack.Str,
    max: memorypack.Str,
    null_count: u32,
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
    columns: []Column,
    validity: [][]const u8 = &.{},
    dictionaries: []Dictionary = &.{},
    codes: [][]const u32 = &.{},
};
pub const Dictionary = struct {
    pub const memorypack_version_tolerant = true;
    values: []const memorypack.Str,
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
        for (manifest.chunks) |chunk| {
            var zones: std.ArrayList(ZoneMap) = .empty;
            errdefer zones.deinit(allocator);
            for (chunk.zone_maps) |zone| try zones.append(allocator, .{
                .min = .{ .bytes = try allocator.dupe(u8, zone.min.bytes) },
                .max = .{ .bytes = try allocator.dupe(u8, zone.max.bytes) },
                .null_count = zone.null_count,
            });
            try table.chunks.append(allocator, .{ .id = chunk.id, .rows = chunk.rows, .zone_maps = try zones.toOwnedSlice(allocator) });
        }
        for (manifest.schema) |column| allocator.free(column.name.bytes);
        for (manifest.chunks) |chunk| for (chunk.zone_maps) |zone| {
            allocator.free(zone.min.bytes);
            allocator.free(zone.max.bytes);
        };
        allocator.free(manifest.schema);
        for (manifest.chunks) |chunk| allocator.free(chunk.zone_maps);
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
        for (self.chunks.items) |chunk| {
            for (chunk.zone_maps) |zone| {
                self.allocator.free(zone.min.bytes);
                self.allocator.free(zone.max.bytes);
            }
            self.allocator.free(chunk.zone_maps);
        }
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

    pub fn getChunkMeta(self: *Table) ![]const ChunkMeta {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.closed) return error.TableClosed;
        return self.chunks.items;
    }

    pub fn appendChunk(self: *Table, columns: []const Column) !u32 {
        return self.appendChunkWithValidity(columns, &.{});
    }

    pub fn appendChunkWithValidity(self: *Table, columns: []const Column, supplied_validity: []const []const u8) !u32 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.closed) return error.TableClosed;
        const rows = try validateColumns(self.schema.items, columns);
        if (rows == 0 or rows > self.chunk_rows) return error.InvalidChunk;
        const id = self.next_chunk;
        var validity: std.ArrayList([]const u8) = .empty;
        defer validity.deinit(self.allocator);
        var dictionaries: std.ArrayList(Dictionary) = .empty;
        defer dictionaries.deinit(self.allocator);
        var codes: std.ArrayList([]const u32) = .empty;
        defer codes.deinit(self.allocator);
        for (columns, 0..) |column, index| {
            const count = columnLength(column);
            if (supplied_validity.len == 0) {
                const bitmap = try self.allocator.alloc(u8, (count + 7) / 8);
                @memset(bitmap, 0xff);
                if (count % 8 != 0) bitmap[bitmap.len - 1] &= @as(u8, @intCast((@as(u16, 1) << @intCast(count % 8)) - 1));
                try validity.append(self.allocator, bitmap);
            } else {
                if (supplied_validity.len != columns.len or supplied_validity[index].len != (count + 7) / 8) return error.InvalidChunk;
                try validity.append(self.allocator, try self.allocator.dupe(u8, supplied_validity[index]));
            }
            if (self.schema.items[index].kind == .string) {
                var values: std.ArrayList(memorypack.Str) = .empty;
                var code_values = try self.allocator.alloc(u32, count);
                defer self.allocator.free(code_values);
                const strings = column.string;
                for (strings, 0..) |value, row| {
                    var found: ?u32 = null;
                    for (values.items, 0..) |existing, dictionary_index| if (std.mem.eql(u8, existing.bytes, value.bytes)) {
                        found = @intCast(dictionary_index);
                        break;
                    };
                    if (found) |code| code_values[row] = code else {
                        try values.append(self.allocator, .{ .bytes = try self.allocator.dupe(u8, value.bytes) });
                        code_values[row] = @intCast(values.items.len - 1);
                    }
                }
                const dictionary = try values.toOwnedSlice(self.allocator);
                try dictionaries.append(self.allocator, .{ .values = dictionary });
                try codes.append(self.allocator, try self.allocator.dupe(u32, code_values));
                values = .empty;
            } else {
                try dictionaries.append(self.allocator, .{ .values = try self.allocator.alloc(memorypack.Str, 0) });
                try codes.append(self.allocator, try self.allocator.alloc(u32, 0));
            }
        }
        const chunk = Chunk{ .columns = @constCast(columns), .validity = validity.items, .dictionaries = dictionaries.items, .codes = codes.items };
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
        const zone_maps = try buildZoneMaps(self.allocator, columns, validity.items);
        errdefer freeZoneMaps(self.allocator, zone_maps);
        try self.chunks.append(self.allocator, .{ .id = id, .rows = @intCast(rows), .zone_maps = zone_maps });
        for (validity.items) |bitmap| self.allocator.free(bitmap);
        for (dictionaries.items) |dictionary| {
            for (dictionary.values) |value| self.allocator.free(value.bytes);
            self.allocator.free(dictionary.values);
        }
        for (codes.items) |column_codes| if (column_codes.len > 0) self.allocator.free(column_codes);
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
        var chunk = try memorypack.decode(Chunk, self.allocator, bytes);
        if (chunk.dictionaries.len == chunk.columns.len and chunk.codes.len == chunk.columns.len) {
            for (chunk.columns, 0..) |column, index| if (column == .string and chunk.codes[index].len > 0) {
                const decoded = try self.allocator.alloc(memorypack.Str, chunk.codes[index].len);
                for (chunk.codes[index], 0..) |code, row| {
                    if (code >= chunk.dictionaries[index].values.len) return error.InvalidChunk;
                    decoded[row] = .{ .bytes = try self.allocator.dupe(u8, chunk.dictionaries[index].values[code].bytes) };
                }
                for (chunk.columns[index].string) |value| self.allocator.free(value.bytes);
                self.allocator.free(chunk.columns[index].string);
                chunk.columns[index] = .{ .string = decoded };
            };
        }
        return chunk;
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

fn freeZoneMaps(allocator: std.mem.Allocator, zones: []const ZoneMap) void {
    for (zones) |zone| {
        allocator.free(zone.min.bytes);
        allocator.free(zone.max.bytes);
    }
    allocator.free(zones);
}

fn buildZoneMaps(allocator: std.mem.Allocator, columns: []const Column, validity: []const []const u8) ![]const ZoneMap {
    const zones = try allocator.alloc(ZoneMap, columns.len);
    for (zones) |*zone| zone.* = .{ .min = .{ .bytes = &.{} }, .max = .{ .bytes = &.{} }, .null_count = 0 };
    errdefer {
        for (zones) |zone| {
            if (zone.min.bytes.len > 0) allocator.free(zone.min.bytes);
            if (zone.max.bytes.len > 0) allocator.free(zone.max.bytes);
        }
        allocator.free(zones);
    }
    for (columns, 0..) |column, index| {
        var null_count: u32 = 0;
        for (0..columnLength(column)) |row| {
            if ((validity[index][row / 8] & (@as(u8, 1) << @intCast(row % 8))) == 0) null_count += 1;
        }
        var min: []u8 = &.{};
        var max: []u8 = &.{};
        switch (column) {
            .i64 => |values| {
                var lo = values[0];
                var hi = values[0];
                for (values, 0..) |value, row| if ((validity[index][row / 8] & (@as(u8, 1) << @intCast(row % 8))) != 0) {
                    lo = @min(lo, value);
                    hi = @max(hi, value);
                };
                min = try std.fmt.allocPrint(allocator, "{d}", .{lo});
                max = try std.fmt.allocPrint(allocator, "{d}", .{hi});
            },
            .f64 => |values| {
                var lo = values[0];
                var hi = values[0];
                for (values, 0..) |value, row| if ((validity[index][row / 8] & (@as(u8, 1) << @intCast(row % 8))) != 0) {
                    lo = @min(lo, value);
                    hi = @max(hi, value);
                };
                min = try std.fmt.allocPrint(allocator, "{d}", .{lo});
                max = try std.fmt.allocPrint(allocator, "{d}", .{hi});
            },
            .bool => |values| {
                min = try allocator.dupe(u8, if (values.len == 0 or !values[0]) "0" else "1");
                max = try allocator.dupe(u8, if (values.len == 0 or values[values.len - 1]) "1" else "0");
            },
            .string => |values| {
                var lo = values[0].bytes;
                var hi = values[0].bytes;
                for (values, 0..) |value, row| if ((validity[index][row / 8] & (@as(u8, 1) << @intCast(row % 8))) != 0) {
                    if (std.mem.order(u8, value.bytes, lo) == .lt) lo = value.bytes;
                    if (std.mem.order(u8, value.bytes, hi) == .gt) hi = value.bytes;
                };
                min = try allocator.dupe(u8, lo);
                max = try allocator.dupe(u8, hi);
            },
        }
        zones[index] = .{ .min = .{ .bytes = min }, .max = .{ .bytes = max }, .null_count = null_count };
    }
    return zones;
}

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
    for (chunk.validity) |bitmap| if (bitmap.len > 0) allocator.free(bitmap);
    for (chunk.dictionaries) |dictionary| {
        for (dictionary.values) |value| allocator.free(value.bytes);
        allocator.free(dictionary.values);
    }
    for (chunk.codes) |column_codes| allocator.free(column_codes);
    if (chunk.validity.len > 0) allocator.free(chunk.validity);
    if (chunk.dictionaries.len > 0) allocator.free(chunk.dictionaries);
    if (chunk.codes.len > 0) allocator.free(chunk.codes);
    allocator.free(chunk.columns);
}

fn columnLength(column: Column) usize {
    return switch (column) {
        .i64 => |values| values.len,
        .f64 => |values| values.len,
        .bool => |values| values.len,
        .string => |values| values.len,
    };
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
