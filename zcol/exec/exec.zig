const std = @import("std");
const memorypack = @import("memorypack");
const storage = @import("storage");

pub const CompareOp = enum(u8) { eq, lt, lte, gt, gte, neq };
pub const Scalar = union(enum) {
    null: void,
    i64: i64,
    f64: f64,
    bool: bool,
    string: memorypack.Str,
};
pub const Predicate = struct {
    column: usize,
    op: CompareOp,
    value: Scalar,
    null_check: ?bool = null,
};
pub const AggregateKind = enum(u8) { count, sum, min, max, avg };
pub const Aggregate = struct {
    kind: AggregateKind,
    column: ?usize,
};
pub const Query = struct {
    projection: []const usize = &.{},
    predicates: []const Predicate = &.{},
    aggregates: []const Aggregate = &.{},
    group_by: ?usize = null,
    group_by_columns: []const usize = &.{},
    order_by: ?usize = null,
    order_desc: bool = false,
    limit: ?usize = null,
};
pub const Value = Scalar;
pub const Row = []Value;
pub fn scalarSumF64(values: []const f64) f64 {
    var total: f64 = 0;
    for (values) |value| total += value;
    return total;
}

pub fn simdSumF64(values: []const f64) f64 {
    const width = 4;
    var index: usize = 0;
    var lanes: @Vector(width, f64) = @splat(0);
    while (index + width <= values.len) : (index += width) lanes += values[index..][0..width].*;
    var total: f64 = @reduce(.Add, lanes);
    while (index < values.len) : (index += 1) total += values[index];
    return total;
}

pub fn scalarFilterF64(values: []const f64, op: CompareOp, rhs: f64, output: []bool) void {
    for (values, 0..) |value, index| output[index] = compareFloat(value, op, rhs);
}

pub fn simdFilterF64(values: []const f64, op: CompareOp, rhs: f64, output: []bool) void {
    const width = 4;
    var index: usize = 0;
    const right: @Vector(width, f64) = @splat(rhs);
    while (index + width <= values.len) : (index += width) {
        const left: @Vector(width, f64) = values[index..][0..width].*;
        const mask = switch (op) {
            .eq => left == right,
            .lt => left < right,
            .lte => left <= right,
            .gt => left > right,
            .gte => left >= right,
            .neq => left != right,
        };
        inline for (0..width) |lane| output[index + lane] = mask[lane];
    }
    while (index < values.len) : (index += 1) output[index] = compareFloat(values[index], op, rhs);
}
pub const Result = struct {
    allocator: std.mem.Allocator,
    columns: []memorypack.Str,
    rows: []Row,

    pub fn deinit(self: *Result) void {
        for (self.columns) |column| self.allocator.free(column.bytes);
        self.allocator.free(self.columns);
        for (self.rows) |row| {
            for (row) |value| freeValue(self.allocator, value);
            self.allocator.free(row);
        }
        self.allocator.free(self.rows);
    }
};

const Group = struct {
    keys: []Value,
    values: []AggState,
};
const AggState = struct {
    count: usize = 0,
    sum: f64 = 0,
    min: f64 = std.math.inf(f64),
    max: f64 = -std.math.inf(f64),
};

pub fn execute(allocator: std.mem.Allocator, table: *storage.Table, query: Query) !Result {
    const schema = try table.getSchema();
    try validateQuery(schema, query);
    var result = Result{ .allocator = allocator, .columns = try allocator.alloc(memorypack.Str, 0), .rows = try allocator.alloc(Row, 0) };
    errdefer result.deinit();
    result.columns = try buildResultColumns(allocator, schema, query);
    var rows: std.ArrayList(Row) = .empty;
    errdefer freeRows(allocator, rows.items);
    var groups: std.ArrayList(Group) = .empty;
    defer {
        for (groups.items) |group| {
            for (group.keys) |key| freeValue(allocator, key);
            allocator.free(group.keys);
            allocator.free(group.values);
        }
        groups.deinit(allocator);
    }
    var group_map = std.StringHashMap(usize).init(allocator);
    defer {
        var iterator = group_map.iterator();
        while (iterator.next()) |entry| allocator.free(entry.key_ptr.*);
        group_map.deinit();
    }
    const chunks = try table.stats();
    var chunk_id: u32 = 0;
    while (chunk_id < chunks.chunks) : (chunk_id += 1) {
        var chunk = try table.readChunk(chunk_id);
        defer storage.freeChunk(allocator, &chunk);
        const row_count = columnLength(chunk.columns[0]);
        const selected = try allocator.alloc(bool, row_count);
        defer allocator.free(selected);
        for (selected) |*value| value.* = true;
        for (query.predicates) |predicate| {
            for (selected, 0..) |*keep, row| {
                if (keep.*) {
                    if (predicate.null_check) |is_null| {
                        if (valid(chunk, predicate.column, row) == is_null) keep.* = false;
                    } else if (!valid(chunk, predicate.column, row) or !matches(chunk.columns[predicate.column], row, predicate)) keep.* = false;
                }
            }
        }
        if (query.aggregates.len == 0 and query.group_by == null and query.group_by_columns.len == 0) {
            for (selected, 0..) |keep, row| if (keep) try rows.append(allocator, try projectRow(allocator, chunk.columns, query.projection, row));
        } else if (query.group_by_columns.len > 0 or query.group_by != null) {
            const group_columns = if (query.group_by_columns.len > 0) query.group_by_columns else &[_]usize{query.group_by.?};
            for (selected, 0..) |keep, row| {
                if (!keep) continue;
                const keys = try allocator.alloc(Value, group_columns.len);
                errdefer allocator.free(keys);
                for (group_columns, 0..) |group_column, key_index| keys[key_index] = try columnValueAt(allocator, chunk, group_column, row);
                const encoded = try valuesKey(allocator, keys);
                defer allocator.free(encoded);
                var is_new = false;
                const group_index = if (group_map.get(encoded)) |index| index else blk: {
                    const values = try allocator.alloc(AggState, query.aggregates.len);
                    @memset(values, .{});
                    try groups.append(allocator, .{ .keys = keys, .values = values });
                    const index = groups.items.len - 1;
                    try group_map.put(try allocator.dupe(u8, encoded), index);
                    is_new = true;
                    break :blk index;
                };
                if (!is_new) {
                    for (keys) |key| freeValue(allocator, key);
                    allocator.free(keys);
                }
                updateAggregates(&groups.items[group_index], chunk, query.aggregates, row);
            }
        } else {
            if (groups.items.len == 0) {
                const values = try allocator.alloc(AggState, query.aggregates.len);
                @memset(values, .{});
                try groups.append(allocator, .{ .keys = &.{}, .values = values });
            }
            for (selected, 0..) |keep, row| if (keep) updateAggregates(&groups.items[0], chunk, query.aggregates, row);
        }
    }
    if (query.aggregates.len > 0) {
        for (groups.items) |group| {
            const group_count: usize = if (query.group_by_columns.len > 0) query.group_by_columns.len else if (query.group_by != null) 1 else 0;
            var row = try allocator.alloc(Value, query.aggregates.len + group_count);
            var index: usize = 0;
            if (group_count > 0) {
                for (group.keys, 0..) |key, key_index| row[key_index] = try cloneValue(allocator, key);
                index = group_count;
            }
            for (query.aggregates, 0..) |aggregate, aggregate_index| row[index + aggregate_index] = aggregateValue(group.values[aggregate_index], aggregate.kind);
            try rows.append(allocator, row);
        }
    }
    result.rows = try rows.toOwnedSlice(allocator);
    return result;
}

fn validateQuery(schema: []const storage.ColumnSchema, query: Query) !void {
    for (query.projection) |column| if (column >= schema.len) return error.ColumnNotFound;
    for (query.predicates) |predicate| if (predicate.column >= schema.len) return error.ColumnNotFound;
    for (query.aggregates) |aggregate| if (aggregate.column == null and aggregate.kind != .count) return error.InvalidQuery else if (aggregate.column) |column| if (column >= schema.len) return error.ColumnNotFound;
    if (query.group_by) |column| if (column >= schema.len) return error.ColumnNotFound;
    for (query.group_by_columns) |column| if (column >= schema.len) return error.ColumnNotFound;
}

fn buildResultColumns(allocator: std.mem.Allocator, schema: []const storage.ColumnSchema, query: Query) ![]memorypack.Str {
    var names: std.ArrayList(memorypack.Str) = .empty;
    errdefer for (names.items) |name| allocator.free(name.bytes);
    if (query.aggregates.len > 0) {
        if (query.group_by_columns.len > 0) for (query.group_by_columns) |column| try names.append(allocator, .{ .bytes = try allocator.dupe(u8, schema[column].name.bytes) }) else if (query.group_by) |column| try names.append(allocator, .{ .bytes = try allocator.dupe(u8, schema[column].name.bytes) });
        for (query.aggregates) |aggregate| {
            const name = switch (aggregate.kind) {
                .count => "count",
                .sum => "sum",
                .min => "min",
                .max => "max",
                .avg => "avg",
            };
            try names.append(allocator, .{ .bytes = try allocator.dupe(u8, name) });
        }
    } else for (query.projection) |column| try names.append(allocator, .{ .bytes = try allocator.dupe(u8, schema[column].name.bytes) });
    return names.toOwnedSlice(allocator);
}

fn columnLength(column: storage.Column) usize {
    return switch (column) {
        .i64 => |values| values.len,
        .f64 => |values| values.len,
        .bool => |values| values.len,
        .string => |values| values.len,
    };
}

fn matches(column: storage.Column, row: usize, predicate: Predicate) bool {
    return switch (column) {
        .i64 => |values| compareInt(values[row], predicate.op, predicate.value.i64),
        .f64 => |values| compareFloat(values[row], predicate.op, predicate.value.f64),
        .bool => |values| predicate.op == .eq and values[row] == predicate.value.bool,
        .string => |values| predicate.op == .eq and std.mem.eql(u8, values[row].bytes, predicate.value.string.bytes),
    };
}

fn valid(chunk: storage.Chunk, column: usize, row: usize) bool {
    if (chunk.validity.len == 0) return true;
    const bitmap = chunk.validity[column];
    return (bitmap[row / 8] & (@as(u8, 1) << @intCast(row % 8))) != 0;
}

fn compareInt(left: i64, op: CompareOp, right: i64) bool {
    return switch (op) {
        .eq => left == right,
        .lt => left < right,
        .lte => left <= right,
        .gt => left > right,
        .gte => left >= right,
        .neq => left != right,
    };
}
fn compareFloat(left: f64, op: CompareOp, right: f64) bool {
    return switch (op) {
        .eq => left == right,
        .lt => left < right,
        .lte => left <= right,
        .gt => left > right,
        .gte => left >= right,
        .neq => left != right,
    };
}

fn projectRow(allocator: std.mem.Allocator, columns: []const storage.Column, projection: []const usize, row: usize) !Row {
    const values = try allocator.alloc(Value, projection.len);
    errdefer allocator.free(values);
    for (projection, 0..) |column, index| values[index] = try columnValue(allocator, columns[column], row);
    return values;
}

fn columnValue(allocator: std.mem.Allocator, column: storage.Column, row: usize) !Value {
    return switch (column) {
        .i64 => |values| .{ .i64 = values[row] },
        .f64 => |values| .{ .f64 = values[row] },
        .bool => |values| .{ .bool = values[row] },
        .string => |values| .{ .string = .{ .bytes = try allocator.dupe(u8, values[row].bytes) } },
    };
}

fn columnValueAt(allocator: std.mem.Allocator, chunk: storage.Chunk, column: usize, row: usize) !Value {
    if (!valid(chunk, column, row)) return .{ .null = {} };
    return columnValue(allocator, chunk.columns[column], row);
}

fn valuesKey(allocator: std.mem.Allocator, values: []const Value) ![]u8 {
    var result: std.ArrayList(u8) = .empty;
    for (values) |value| {
        const part = try valueKey(allocator, value);
        defer allocator.free(part);
        try result.appendSlice(allocator, part);
        try result.append(allocator, 0);
    }
    return result.toOwnedSlice(allocator);
}

fn updateAggregates(group: *Group, chunk: storage.Chunk, aggregates: []const Aggregate, row: usize) void {
    for (aggregates, 0..) |aggregate, index| {
        if (aggregate.column) |column| {
            if (!valid(chunk, column, row)) continue;
            group.values[index].count += 1;
        } else group.values[index].count += 1;
        if (aggregate.column) |column| {
            const numeric = switch (chunk.columns[column]) {
                .i64 => |values| @as(f64, @floatFromInt(values[row])),
                .f64 => |values| values[row],
                else => 0,
            };
            group.values[index].sum += numeric;
            group.values[index].min = @min(group.values[index].min, numeric);
            group.values[index].max = @max(group.values[index].max, numeric);
        }
    }
}

fn aggregateValue(state: AggState, kind: AggregateKind) Value {
    return switch (kind) {
        .count => .{ .i64 = @intCast(state.count) },
        .sum => .{ .f64 = state.sum },
        .min => .{ .f64 = state.min },
        .max => .{ .f64 = state.max },
        .avg => .{ .f64 = if (state.count == 0) 0 else state.sum / @as(f64, @floatFromInt(state.count)) },
    };
}

fn valueKey(allocator: std.mem.Allocator, value: Value) ![]u8 {
    return switch (value) {
        .i64 => |v| std.fmt.allocPrint(allocator, "i:{d}", .{v}),
        .f64 => |v| std.fmt.allocPrint(allocator, "f:{d}", .{v}),
        .bool => |v| std.fmt.allocPrint(allocator, "b:{d}", .{@intFromBool(v)}),
        .string => |v| std.fmt.allocPrint(allocator, "s:{s}", .{v.bytes}),
        .null => std.fmt.allocPrint(allocator, "n", .{}),
    };
}

fn cloneValue(allocator: std.mem.Allocator, value: Value) !Value {
    return switch (value) {
        .string => |v| .{ .string = .{ .bytes = try allocator.dupe(u8, v.bytes) } },
        else => value,
    };
}
fn freeValue(allocator: std.mem.Allocator, value: Value) void {
    switch (value) {
        .string => |v| allocator.free(v.bytes),
        else => {},
    }
}
fn freeRows(allocator: std.mem.Allocator, rows: []Row) void {
    for (rows) |row| {
        for (row) |value| freeValue(allocator, value);
        allocator.free(row);
    }
    allocator.free(rows);
}

test "vectorized filter aggregates and group by" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    const dir = "zig-cache/zcol-exec";
    std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    const schema = [_]storage.ColumnSchema{
        .{ .name = .{ .bytes = "amount" }, .kind = .f64 },
        .{ .name = .{ .bytes = "team" }, .kind = .string },
    };
    var table = try storage.Table.create(io, allocator, dir, &schema, 4);
    defer table.deinit();
    const teams = [_]memorypack.Str{ .{ .bytes = "a" }, .{ .bytes = "a" }, .{ .bytes = "b" }, .{ .bytes = "b" } };
    _ = try table.appendChunk(&.{ .{ .f64 = &.{ 10, 20, 30, 40 } }, .{ .string = &teams } });
    const predicates = [_]Predicate{.{ .column = 0, .op = .gte, .value = .{ .f64 = 20 } }};
    const aggregates = [_]Aggregate{ .{ .kind = .sum, .column = 0 }, .{ .kind = .count, .column = null } };
    var result = try execute(allocator, &table, .{ .predicates = &predicates, .aggregates = &aggregates, .group_by = 1 });
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 2), result.rows.len);
    try std.testing.expectEqual(@as(f64, 20), result.rows[0][1].f64);
    try std.testing.expectEqual(@as(i64, 1), result.rows[0][2].i64);
    try std.testing.expectEqual(@as(f64, 70), result.rows[1][1].f64);
    try std.testing.expectEqual(@as(i64, 2), result.rows[1][2].i64);
}

test "null validity skips aggregates and forms a null group" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    const dir = "zig-cache/zcol-exec-null";
    std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    const schema = [_]storage.ColumnSchema{
        .{ .name = .{ .bytes = "amount" }, .kind = .f64 },
        .{ .name = .{ .bytes = "team" }, .kind = .string },
    };
    var table = try storage.Table.create(io, allocator, dir, &schema, 4);
    defer table.deinit();
    const teams = [_]memorypack.Str{ .{ .bytes = "a" }, .{ .bytes = "a" }, .{ .bytes = "b" }, .{ .bytes = "b" } };
    const validity = [_][]const u8{ &.{0b00000101}, &.{0b00000011} };
    _ = try table.appendChunkWithValidity(&.{ .{ .f64 = &.{ 10, 20, 30, 40 } }, .{ .string = &teams } }, &validity);
    const aggregates = [_]Aggregate{ .{ .kind = .sum, .column = 0 }, .{ .kind = .count, .column = 0 }, .{ .kind = .count, .column = null } };
    var result = try execute(allocator, &table, .{ .aggregates = &aggregates, .group_by = 1 });
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 2), result.rows.len);
    try std.testing.expectEqual(@as(i64, 1), result.rows[0][2].i64);
    try std.testing.expectEqual(@as(i64, 2), result.rows[0][3].i64);
    try std.testing.expectEqual(@as(i64, 1), result.rows[1][2].i64);
    try std.testing.expectEqual(@as(i64, 2), result.rows[1][3].i64);
}

test "SIMD and scalar numeric paths agree" {
    const values = [_]f64{ 1, 4, 7, 10, 13, 16, 19 };
    var scalar = [_]bool{false} ** values.len;
    var vector = [_]bool{false} ** values.len;
    scalarFilterF64(&values, .gte, 10, &scalar);
    simdFilterF64(&values, .gte, 10, &vector);
    try std.testing.expectEqualSlices(bool, &scalar, &vector);
    try std.testing.expectEqual(scalarSumF64(&values), simdSumF64(&values));
}
