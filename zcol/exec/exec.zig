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
    pushdown: bool = true,
    threads: usize = 1,
};
pub fn parallelSumF64(allocator: std.mem.Allocator, values: []const f64, thread_count: usize) !f64 {
    if (thread_count <= 1 or values.len < 4096) return scalarSumF64(values);
    const count = @min(thread_count, values.len);
    const contexts = try allocator.alloc(ParallelSumContext, count);
    defer allocator.free(contexts);
    const threads = try allocator.alloc(std.Thread, count);
    defer allocator.free(threads);
    for (0..count) |index| {
        const start = values.len * index / count;
        const end = values.len * (index + 1) / count;
        contexts[index] = .{ .values = values, .start = start, .end = end };
        threads[index] = try std.Thread.spawn(.{}, parallelSumWorker, .{&contexts[index]});
    }
    var total: f64 = 0;
    for (threads, 0..) |thread, index| {
        thread.join();
        total += contexts[index].result;
    }
    return total;
}
const ParallelSumContext = struct { values: []const f64, start: usize, end: usize, result: f64 = 0 };
fn parallelSumWorker(context: *ParallelSumContext) void {
    context.result = scalarSumF64(context.values[context.start..context.end]);
}
pub const Value = Scalar;
pub const Row = []Value;
pub const JoinProjection = struct {
    left: bool,
    column: usize,
    name: memorypack.Str,
};
pub const JoinKind = enum { inner, left, right, full };
pub const JoinQuery = struct {
    left_key: usize,
    right_key: usize,
    projection: []const JoinProjection,
    left_keys: []const usize = &.{},
    right_keys: []const usize = &.{},
    kind: JoinKind = .inner,
    order_by: ?usize = null,
    order_desc: bool = false,
    limit: ?usize = null,
};
pub const WindowKind = enum { row_number, rank, dense_rank, running_sum, running_avg, running_count };
pub const WindowQuery = struct {
    partition_by: []const usize,
    order_by: usize,
    order_desc: bool = false,
    value_column: ?usize = null,
    functions: []const WindowKind,
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
    chunks_scanned: usize = 0,
    chunks_skipped: usize = 0,
    late_materialized_bytes_saved: usize = 0,

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
    var map = std.StringHashMap(std.ArrayList(usize)).init(allocator);
    defer {
        var iterator = map.iterator();
        while (iterator.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(allocator);
        }
        map.deinit();
    }
    const left_keys = if (query.left_keys.len > 0) query.left_keys else &[_]usize{query.left_key};
    const right_keys = if (query.right_keys.len > 0) query.right_keys else &[_]usize{query.right_key};
    var left_matched = try allocator.alloc(bool, 0);
    defer allocator.free(left_matched);
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
            left_matched = try allocator.realloc(left_matched, left_rows.items.len);
            left_matched[index] = false;
            if (try joinKey(allocator, values, left_keys)) |key| {
                if (map.getPtr(key)) |indices| {
                    allocator.free(key);
                    try indices.append(allocator, index);
                } else {
                    var indices: std.ArrayList(usize) = .empty;
                    try indices.append(allocator, index);
                    try map.put(key, indices);
                }
            }
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
            var right_values = try allocator.alloc(Value, chunk.columns.len);
            defer {
                for (right_values) |value| freeValue(allocator, value);
                allocator.free(right_values);
            }
            for (chunk.columns, 0..) |_, column_index| right_values[column_index] = try columnValueAt(allocator, chunk, column_index, row);
            const maybe_key = try joinKey(allocator, right_values, right_keys);
            if (maybe_key) |key| {
                defer allocator.free(key);
                if (map.get(key)) |indices| {
                    for (indices.items) |left_index| {
                        left_matched[left_index] = true;
                        try appendJoinRow(allocator, &output_rows, query.projection, left_rows.items[left_index], right_values);
                    }
                } else if (query.kind == .right or query.kind == .full) {
                    try appendJoinRow(allocator, &output_rows, query.projection, null, right_values);
                }
            } else if (query.kind == .right or query.kind == .full) {
                try appendJoinRow(allocator, &output_rows, query.projection, null, right_values);
            }
        }
    }
    if (query.kind == .left or query.kind == .full) {
        for (left_rows.items, 0..) |left_values, left_index| {
            if (!left_matched[left_index]) try appendJoinRow(allocator, &output_rows, query.projection, left_values, null);
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

fn joinKey(allocator: std.mem.Allocator, values: []const Value, keys: []const usize) !?[]u8 {
    for (keys) |column| if (values[column] == .null) return null;
    var selected = try allocator.alloc(Value, keys.len);
    defer allocator.free(selected);
    for (keys, 0..) |column, index| selected[index] = values[column];
    return try valuesKey(allocator, selected);
}

fn appendJoinRow(
    allocator: std.mem.Allocator,
    rows: *std.ArrayList(Row),
    projection: []const JoinProjection,
    left: ?[]const Value,
    right: ?[]const Value,
) !void {
    const output = try allocator.alloc(Value, projection.len);
    errdefer allocator.free(output);
    for (projection, 0..) |item, index| {
        const source = if (item.left) left else right;
        output[index] = if (source) |values| try cloneValue(allocator, values[item.column]) else .{ .null = {} };
    }
    try rows.append(allocator, output);
}

pub fn executeWindow(allocator: std.mem.Allocator, table: *storage.Table, query: WindowQuery) !Result {
    const schema = try table.getSchema();
    var source: std.ArrayList(Row) = .empty;
    defer {
        freeRowValues(allocator, source.items);
        source.deinit(allocator);
    }
    const stats = try table.stats();
    var chunk_id: u32 = 0;
    while (chunk_id < stats.chunks) : (chunk_id += 1) {
        var chunk = try table.readChunk(chunk_id);
        defer storage.freeChunk(allocator, &chunk);
        const row_count = columnLength(chunk.columns[0]);
        for (0..row_count) |row| {
            const values = try allocator.alloc(Value, chunk.columns.len);
            errdefer allocator.free(values);
            for (chunk.columns, 0..) |_, column| values[column] = try columnValueAt(allocator, chunk, column, row);
            try source.append(allocator, values);
        }
    }
    var order: std.ArrayList(usize) = .empty;
    defer order.deinit(allocator);
    try order.ensureTotalCapacity(allocator, source.items.len);
    for (source.items, 0..) |_, index| try order.append(allocator, index);
    const context = WindowSortContext{ .rows = source.items, .partition_by = query.partition_by, .order_by = query.order_by, .descending = query.order_desc };
    std.mem.sort(usize, order.items, context, lessWindowRows);
    var result = Result{ .allocator = allocator, .columns = try allocator.alloc(memorypack.Str, schema.len + query.functions.len), .rows = try allocator.alloc(Row, 0) };
    errdefer result.deinit();
    for (schema, 0..) |column, index| result.columns[index] = .{ .bytes = try allocator.dupe(u8, column.name.bytes) };
    const names = [_][]const u8{ "row_number", "rank", "dense_rank", "running_sum", "running_avg", "running_count" };
    for (query.functions, 0..) |function, index| result.columns[schema.len + index] = .{ .bytes = try allocator.dupe(u8, names[@intFromEnum(function)]) };
    var output: std.ArrayList(Row) = .empty;
    errdefer freeRowValues(allocator, output.items);
    var partition_start: usize = 0;
    while (partition_start < order.items.len) {
        var partition_end = partition_start + 1;
        while (partition_end < order.items.len and samePartition(source.items[order.items[partition_start]], source.items[order.items[partition_end]], query.partition_by)) : (partition_end += 1) {}
        var rank: usize = 1;
        var dense_rank: usize = 1;
        var previous_order: ?Value = null;
        var sum: f64 = 0;
        var count: usize = 0;
        for (order.items[partition_start..partition_end], 0..) |row_index, offset| {
            const row = try allocator.alloc(Value, result.columns.len);
            errdefer allocator.free(row);
            for (source.items[row_index], 0..) |value, column| row[column] = try cloneValue(allocator, value);
            if (previous_order) |previous| {
                if (compareValue(previous, source.items[row_index][query.order_by]) != 0) {
                    rank = offset + 1;
                    dense_rank += 1;
                }
            }
            freeValue(allocator, previous_order orelse .{ .null = {} });
            previous_order = try cloneValue(allocator, source.items[row_index][query.order_by]);
            if (query.value_column) |column| if (source.items[row_index][column] != .null) {
                count += 1;
                sum += numericValue(source.items[row_index][column]);
            };
            for (query.functions, 0..) |function, function_index| row[schema.len + function_index] = switch (function) {
                .row_number => .{ .i64 = @intCast(offset + 1) },
                .rank => .{ .i64 = @intCast(rank) },
                .dense_rank => .{ .i64 = @intCast(dense_rank) },
                .running_sum => .{ .f64 = sum },
                .running_avg => if (count == 0) .{ .null = {} } else .{ .f64 = sum / @as(f64, @floatFromInt(count)) },
                .running_count => .{ .i64 = @intCast(count) },
            };
            try output.append(allocator, row);
        }
        if (previous_order) |previous| freeValue(allocator, previous);
        partition_start = partition_end;
    }
    result.rows = try output.toOwnedSlice(allocator);
    result.storage_rows = result.rows;
    result.storage_visible_len = result.rows.len;
    return result;
}

const WindowSortContext = struct { rows: []const Row, partition_by: []const usize, order_by: usize, descending: bool };
fn lessWindowRows(context: WindowSortContext, left: usize, right: usize) bool {
    const left_row = context.rows[left];
    const right_row = context.rows[right];
    for (context.partition_by) |column| {
        const compared = compareValue(left_row[column], right_row[column]);
        if (compared != 0) return compared < 0;
    }
    const compared = compareValue(left_row[context.order_by], right_row[context.order_by]);
    return if (context.descending) compared > 0 else compared < 0;
}
fn samePartition(left: Row, right: Row, columns: []const usize) bool {
    for (columns) |column| if (compareValue(left[column], right[column]) != 0) return false;
    return true;
}
fn numericValue(value: Value) f64 {
    return switch (value) {
        .i64 => |number| @floatFromInt(number),
        .f64 => |number| number,
        else => 0,
    };
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
    var deferred_bytes_per_row: usize = 0;
    for (schema, 0..) |column, index| {
        var projected = false;
        for (query.projection) |selected| {
            if (selected == index) projected = true;
        }
        if (!projected) deferred_bytes_per_row += columnStorageWidth(column.kind);
    }
    if (query.threads > 1 and query.predicates.len == 0 and query.group_by == null and
        query.group_by_columns.len == 0 and query.aggregates.len == 1 and
        query.aggregates[0].kind == .sum and query.aggregates[0].column != null and
        schema[query.aggregates[0].column.?].kind == .f64)
    {
        return executeParallelSum(allocator, table, query, &result);
    }
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
    const metadata = try table.getChunkMeta();
    var chunk_id: u32 = 0;
    while (chunk_id < chunks.chunks) : (chunk_id += 1) {
        if (query.pushdown and canSkipChunk(metadata[chunk_id], schema, query.predicates)) {
            result.chunks_skipped += 1;
            continue;
        }
        result.chunks_scanned += 1;
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
            for (selected, 0..) |keep, row| {
                if (!keep) continue;
                result.late_materialized_bytes_saved += deferred_bytes_per_row;
                try rows.append(allocator, try projectChunkRow(allocator, chunk, query.projection, row));
            }
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

fn columnStorageWidth(kind: storage.ColumnType) usize {
    return switch (kind) {
        .i64, .f64 => 8,
        .bool => 1,
        .string => 4,
    };
}

fn executeParallelSum(allocator: std.mem.Allocator, table: *storage.Table, query: Query, result: *Result) !Result {
    var values: std.ArrayList(f64) = .empty;
    defer values.deinit(allocator);
    const column = query.aggregates[0].column.?;
    const stats = try table.stats();
    for (0..stats.chunks) |chunk_id| {
        var chunk = try table.readChunk(@intCast(chunk_id));
        defer storage.freeChunk(allocator, &chunk);
        if (chunk.columns[column] != .f64) return error.InvalidChunk;
        for (chunk.columns[column].f64, 0..) |value, row| if (valid(chunk, column, row)) try values.append(allocator, value);
    }
    const total = try parallelSumF64(allocator, values.items, query.threads);
    const row = try allocator.alloc(Value, 1);
    row[0] = .{ .f64 = total };
    result.rows = try allocator.alloc(Row, 1);
    result.rows[0] = row;
    result.storage_rows = result.rows;
    result.storage_visible_len = 1;
    return result.*;
}

fn canSkipChunk(meta: storage.ChunkMeta, schema: []const storage.ColumnSchema, predicates: []const Predicate) bool {
    for (predicates) |predicate| {
        if (predicate.column >= meta.zone_maps.len) continue;
        const zone = meta.zone_maps[predicate.column];
        if (predicate.null_check != null) {
            if (predicate.null_check.? and zone.null_count == 0) return true;
            if (!predicate.null_check.? and zone.null_count == meta.rows) return true;
            continue;
        }
        if (zone.null_count == meta.rows) return true;
        const kind = schema[predicate.column].kind;
        if (kind != .i64 and kind != .f64) continue;
        const value = switch (predicate.value) {
            .i64 => |number| @as(f64, @floatFromInt(number)),
            .f64 => |number| number,
            else => continue,
        };
        const low = std.fmt.parseFloat(f64, zone.min.bytes) catch continue;
        const high = std.fmt.parseFloat(f64, zone.max.bytes) catch continue;
        switch (predicate.op) {
            .eq => if (value < low or value > high) return true,
            .lt => if (low >= value) return true,
            .lte => if (low > value) return true,
            .gt => if (high <= value) return true,
            .gte => if (high < value) return true,
            .neq => {},
        }
    }
    return false;
}

const SortContext = struct { column: usize, descending: bool };
fn lessRows(context: SortContext, left: Row, right: Row) bool {
    const result = compareValue(left[context.column], right[context.column]);
    return if (context.descending) result > 0 else result < 0;
}
fn compareValue(left: Value, right: Value) i8 {
    if (left == .null or right == .null) {
        if (left == .null and right == .null) return 0;
        return if (left == .null) -1 else 1;
    }
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

test "composite and outer joins preserve unmatched rows" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    const left_dir = "zig-cache/zcol-join-outer-left";
    const right_dir = "zig-cache/zcol-join-outer-right";
    std.Io.Dir.cwd().deleteTree(io, left_dir) catch {};
    std.Io.Dir.cwd().deleteTree(io, right_dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, left_dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, right_dir) catch {};
    const schema = [_]storage.ColumnSchema{ .{ .name = .{ .bytes = "k" }, .kind = .i64 }, .{ .name = .{ .bytes = "tag" }, .kind = .string } };
    var left = try storage.Table.create(io, allocator, left_dir, &schema, 8);
    defer left.deinit();
    var right = try storage.Table.create(io, allocator, right_dir, &schema, 8);
    defer right.deinit();
    const left_tags = [_]memorypack.Str{ .{ .bytes = "a" }, .{ .bytes = "b" }, .{ .bytes = "c" } };
    const right_tags = [_]memorypack.Str{ .{ .bytes = "a" }, .{ .bytes = "x" }, .{ .bytes = "c" } };
    _ = try left.appendChunk(&.{ .{ .i64 = &.{ 1, 2, 3 } }, .{ .string = &left_tags } });
    _ = try right.appendChunk(&.{ .{ .i64 = &.{ 1, 2, 4 } }, .{ .string = &right_tags } });
    const keys = [_]usize{ 0, 1 };
    const projections = [_]JoinProjection{
        .{ .left = true, .column = 0, .name = .{ .bytes = "left_k" } },
        .{ .left = false, .column = 0, .name = .{ .bytes = "right_k" } },
    };
    inline for ([_]JoinKind{ .left, .right, .full }) |kind| {
        var result = try executeJoin(allocator, &left, &right, .{ .left_key = 0, .right_key = 0, .left_keys = &keys, .right_keys = &keys, .kind = kind, .projection = &projections });
        defer result.deinit();
        const expected = switch (kind) {
            .left, .right => 3,
            .full => 5,
            .inner => 1,
        };
        try std.testing.expectEqual(@as(usize, expected), result.rows.len);
        if (kind == .left) try std.testing.expect(result.rows[2][1] == .null);
        if (kind == .right) try std.testing.expect(result.rows[2][0] == .null);
    }
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

test "window ranking and running sums respect partitions and ties" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    const dir = "zig-cache/zcol-window";
    std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    const schema = [_]storage.ColumnSchema{
        .{ .name = .{ .bytes = "team" }, .kind = .string },
        .{ .name = .{ .bytes = "score" }, .kind = .i64 },
        .{ .name = .{ .bytes = "amount" }, .kind = .f64 },
    };
    var table = try storage.Table.create(io, allocator, dir, &schema, 8);
    defer table.deinit();
    const teams = [_]memorypack.Str{ .{ .bytes = "a" }, .{ .bytes = "a" }, .{ .bytes = "a" }, .{ .bytes = "b" } };
    _ = try table.appendChunk(&.{ .{ .string = &teams }, .{ .i64 = &.{ 2, 1, 1, 3 } }, .{ .f64 = &.{ 20, 10, 5, 7 } } });
    const functions = [_]WindowKind{ .row_number, .rank, .dense_rank, .running_sum, .running_count };
    const partitions = [_]usize{0};
    var result = try executeWindow(allocator, &table, .{ .partition_by = &partitions, .order_by = 1, .value_column = 2, .functions = &functions });
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 4), result.rows.len);
    try std.testing.expectEqual(@as(i64, 1), result.rows[0][3].i64);
    try std.testing.expectEqual(@as(i64, 1), result.rows[0][4].i64);
    try std.testing.expectEqual(@as(i64, 1), result.rows[0][5].i64);
    try std.testing.expect(result.rows[0][6].f64 == 5 or result.rows[0][6].f64 == 10);
    try std.testing.expectEqual(@as(i64, 2), result.rows[1][3].i64);
    try std.testing.expectEqual(@as(i64, 1), result.rows[1][4].i64);
    try std.testing.expectEqual(@as(i64, 1), result.rows[1][5].i64);
    try std.testing.expectEqual(@as(f64, 15), result.rows[1][6].f64);
    try std.testing.expectEqual(@as(i64, 3), result.rows[2][3].i64);
    try std.testing.expectEqual(@as(i64, 3), result.rows[2][4].i64);
    try std.testing.expectEqual(@as(i64, 2), result.rows[2][5].i64);
    try std.testing.expectEqual(@as(f64, 35), result.rows[2][6].f64);
}

test "zone maps skip impossible chunks without changing results" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    const dir = "zig-cache/zcol-zones";
    std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    const schema = [_]storage.ColumnSchema{.{ .name = .{ .bytes = "amount" }, .kind = .f64 }};
    var table = try storage.Table.create(io, allocator, dir, &schema, 2);
    defer table.deinit();
    _ = try table.appendChunk(&.{.{ .f64 = &.{ 1, 2 } }});
    _ = try table.appendChunk(&.{.{ .f64 = &.{ 100, 101 } }});
    const predicates = [_]Predicate{.{ .column = 0, .op = .gte, .value = .{ .f64 = 50 } }};
    var pushed = try execute(allocator, &table, .{ .projection = &.{0}, .predicates = &predicates });
    defer pushed.deinit();
    var serial = try execute(allocator, &table, .{ .projection = &.{0}, .predicates = &predicates, .pushdown = false });
    defer serial.deinit();
    try std.testing.expectEqual(@as(usize, 1), pushed.chunks_skipped);
    try std.testing.expectEqual(@as(usize, 1), pushed.chunks_scanned);
    try std.testing.expectEqual(serial.rows.len, pushed.rows.len);
    try std.testing.expectEqual(@as(f64, 100), pushed.rows[0][0].f64);
}

test "parallel numeric reduction matches serial reduction" {
    const allocator = std.testing.allocator;
    const values = try allocator.alloc(f64, 8192);
    defer allocator.free(values);
    for (values, 0..) |*value, index| value.* = @floatFromInt(index % 17);
    try std.testing.expectEqual(scalarSumF64(values), try parallelSumF64(allocator, values, 4));
}
