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
pub const JoinProjection = struct {
    left: bool,
    column: usize,
    name: memorypack.Str,
};
pub const JoinQuery = struct {
    left_key: usize,
    right_key: usize,
    projection: []const JoinProjection,
    order_by: ?usize = null,
    order_desc: bool = false,
    limit: ?usize = null,
};
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
    storage_rows: []Row = &.{},
    storage_visible_len: usize = 0,

    pub fn deinit(self: *Result) void {
        for (self.columns) |column| self.allocator.free(column.bytes);
        self.allocator.free(self.columns);
        const owned_rows = if (self.storage_rows.len > 0) self.storage_rows else self.rows;
        for (owned_rows[0..self.storage_visible_len]) |row| {
            for (row) |value| freeValue(self.allocator, value);
            self.allocator.free(row);
        }
        if (owned_rows.len > 0) self.allocator.free(owned_rows);
    }
};

pub fn executeJoin(allocator: std.mem.Allocator, left: *storage.Table, right: *storage.Table, query: JoinQuery) !Result {
    var result = Result{ .allocator = allocator, .columns = try allocator.alloc(memorypack.Str, query.projection.len), .rows = try allocator.alloc(Row, 0) };
    errdefer result.deinit();
    for (query.projection, 0..) |projection, index| result.columns[index] = .{ .bytes = try allocator.dupe(u8, projection.name.bytes) };
    var left_rows: std.ArrayList(Row) = .empty;
    defer {
        freeRowValues(allocator, left_rows.items);
        left_rows.deinit(allocator);
    }
    var map = std.StringHashMap(usize).init(allocator);
    defer {
        var iterator = map.iterator();
        while (iterator.next()) |entry| allocator.free(entry.key_ptr.*);
        map.deinit();
    }
    const left_chunks = try left.stats();
    var chunk_id: u32 = 0;
    while (chunk_id < left_chunks.chunks) : (chunk_id += 1) {
        var chunk = try left.readChunk(chunk_id);
        defer storage.freeChunk(allocator, &chunk);
        const rows = columnLength(chunk.columns[0]);
        for (0..rows) |row| {
            const values = try allocator.alloc(Value, chunk.columns.len);
            for (chunk.columns, 0..) |_, column_index| values[column_index] = try columnValueAt(allocator, chunk, column_index, row);
            const index = left_rows.items.len;
            try left_rows.append(allocator, values);
            const key = try valueKey(allocator, values[query.left_key]);
            try map.put(try allocator.dupe(u8, key), index);
            allocator.free(key);
        }
    }
    const right_chunks = try right.stats();
    chunk_id = 0;
    var output_rows: std.ArrayList(Row) = .empty;
    errdefer {
        freeRowValues(allocator, output_rows.items);
        output_rows.deinit(allocator);
    }
    while (chunk_id < right_chunks.chunks) : (chunk_id += 1) {
        var chunk = try right.readChunk(chunk_id);
        defer storage.freeChunk(allocator, &chunk);
        const rows = columnLength(chunk.columns[0]);
        for (0..rows) |row| {
            const key_value = try columnValueAt(allocator, chunk, query.right_key, row);
            const key = try valueKey(allocator, key_value);
            freeValue(allocator, key_value);
            defer allocator.free(key);
            const left_index = map.get(key) orelse continue;
            const output = try allocator.alloc(Value, query.projection.len);
            errdefer allocator.free(output);
            for (query.projection, 0..) |projection, index| output[index] = if (projection.left) try cloneValue(allocator, left_rows.items[left_index][projection.column]) else try columnValueAt(allocator, chunk, projection.column, row);
            try output_rows.append(allocator, output);
        }
    }
    result.rows = try output_rows.toOwnedSlice(allocator);
    result.storage_rows = result.rows;
    result.storage_visible_len = result.rows.len;
    if (query.order_by) |column| {
        if (column < result.columns.len) {
            const context = SortContext{ .column = column, .descending = query.order_desc };
            std.mem.sort(Row, result.rows, context, lessRows);
        }
    }
    if (query.limit) |limit| if (result.rows.len > limit) {
        for (result.rows[limit..]) |row| {
            for (row) |value| freeValue(allocator, value);
            allocator.free(row);
        }
        result.rows = result.rows[0..limit];
        result.storage_visible_len = limit;
    };
    return result;
}

const Group = struct {
    keys: []Value,
    values: []AggState,
};
const AggState = struct {
    count: usize = 0,
    non_null: bool = false,
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
            for (selected, 0..) |keep, row| if (keep) try rows.append(allocator, try projectChunkRow(allocator, chunk, query.projection, row));
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
    result.storage_rows = result.rows;
    result.storage_visible_len = result.rows.len;
    if (query.order_by) |column| {
        if (column < result.columns.len) {
            const sort_context = SortContext{ .column = column, .descending = query.order_desc };
            std.mem.sort(Row, result.rows, sort_context, lessRows);
        }
    }
    if (query.limit) |limit| if (result.rows.len > limit) {
        for (result.rows[limit..]) |row| {
            for (row) |value| freeValue(allocator, value);
            allocator.free(row);
        }
        result.rows = result.rows[0..limit];
        result.storage_visible_len = limit;
    };
    return result;
}

const SortContext = struct { column: usize, descending: bool };
fn lessRows(context: SortContext, left: Row, right: Row) bool {
    const result = compareValue(left[context.column], right[context.column]);
    return if (context.descending) result > 0 else result < 0;
}
fn compareValue(left: Value, right: Value) i8 {
    return switch (left) {
        .i64 => |value| if (value < right.i64) -1 else if (value > right.i64) 1 else 0,
        .f64 => |value| if (value < right.f64) -1 else if (value > right.f64) 1 else 0,
        .string => |value| switch (std.mem.order(u8, value.bytes, right.string.bytes)) {
            .lt => -1,
            .gt => 1,
            .eq => 0,
        },
        .bool => |value| if (!value and right.bool) -1 else if (value and !right.bool) 1 else 0,
        .null => if (right == .null) 0 else -1,
    };
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

fn projectChunkRow(allocator: std.mem.Allocator, chunk: storage.Chunk, projection: []const usize, row: usize) !Row {
    const values = try allocator.alloc(Value, projection.len);
    errdefer allocator.free(values);
    for (projection, 0..) |column, index| values[index] = try columnValueAt(allocator, chunk, column, row);
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
            group.values[index].non_null = true;
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
        .sum => if (!state.non_null) .{ .null = {} } else .{ .f64 = state.sum },
        .min => if (!state.non_null) .{ .null = {} } else .{ .f64 = state.min },
        .max => if (!state.non_null) .{ .null = {} } else .{ .f64 = state.max },
        .avg => if (!state.non_null) .{ .null = {} } else .{ .f64 = state.sum / @as(f64, @floatFromInt(state.count)) },
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
    freeRowValues(allocator, rows);
    allocator.free(rows);
}
fn freeRowValues(allocator: std.mem.Allocator, rows: []Row) void {
    for (rows) |row| {
        for (row) |value| freeValue(allocator, value);
        allocator.free(row);
    }
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

test "single-key inner join orders and limits results" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    const left_dir = "zig-cache/zcol-join-left";
    const right_dir = "zig-cache/zcol-join-right";
    std.Io.Dir.cwd().deleteTree(io, left_dir) catch {};
    std.Io.Dir.cwd().deleteTree(io, right_dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, left_dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, right_dir) catch {};
    const left_schema = [_]storage.ColumnSchema{ .{ .name = .{ .bytes = "id" }, .kind = .i64 }, .{ .name = .{ .bytes = "name" }, .kind = .string } };
    const right_schema = [_]storage.ColumnSchema{ .{ .name = .{ .bytes = "id" }, .kind = .i64 }, .{ .name = .{ .bytes = "score" }, .kind = .f64 } };
    var left = try storage.Table.create(io, allocator, left_dir, &left_schema, 8);
    defer left.deinit();
    var right = try storage.Table.create(io, allocator, right_dir, &right_schema, 8);
    defer right.deinit();
    const names = [_]memorypack.Str{ .{ .bytes = "one" }, .{ .bytes = "two" }, .{ .bytes = "three" } };
    _ = try left.appendChunk(&.{ .{ .i64 = &.{ 1, 2, 3 } }, .{ .string = &names } });
    _ = try right.appendChunk(&.{ .{ .i64 = &.{ 2, 3 } }, .{ .f64 = &.{ 20, 10 } } });
    const projections = [_]JoinProjection{
        .{ .left = true, .column = 1, .name = .{ .bytes = "name" } },
        .{ .left = false, .column = 1, .name = .{ .bytes = "score" } },
    };
    var result = try executeJoin(allocator, &left, &right, .{ .left_key = 0, .right_key = 0, .projection = &projections, .order_by = 1, .order_desc = true, .limit = 1 });
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 1), result.rows.len);
    try std.testing.expectEqualStrings("two", result.rows[0][0].string.bytes);
    try std.testing.expectEqual(@as(f64, 20), result.rows[0][1].f64);
}

test "composite grouping separates mixed keys" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    const dir = "zig-cache/zcol-composite";
    std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    const schema = [_]storage.ColumnSchema{
        .{ .name = .{ .bytes = "team" }, .kind = .string },
        .{ .name = .{ .bytes = "bucket" }, .kind = .i64 },
        .{ .name = .{ .bytes = "amount" }, .kind = .f64 },
    };
    var table = try storage.Table.create(io, allocator, dir, &schema, 8);
    defer table.deinit();
    const teams = [_]memorypack.Str{ .{ .bytes = "a" }, .{ .bytes = "a" }, .{ .bytes = "a" }, .{ .bytes = "b" } };
    _ = try table.appendChunk(&.{ .{ .string = &teams }, .{ .i64 = &.{ 1, 2, 1, 1 } }, .{ .f64 = &.{ 2, 3, 4, 5 } } });
    const groups = [_]usize{ 0, 1 };
    const aggregates = [_]Aggregate{.{ .kind = .sum, .column = 2 }};
    var result = try execute(allocator, &table, .{ .aggregates = &aggregates, .group_by_columns = &groups });
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 3), result.rows.len);
    try std.testing.expectEqual(@as(f64, 6), result.rows[0][2].f64);
    try std.testing.expectEqual(@as(f64, 3), result.rows[1][2].f64);
}
