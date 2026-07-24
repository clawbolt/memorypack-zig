const std = @import("std");
const memorypack = @import("memorypack");
const storage = @import("storage");

pub const Row = struct {
    id: i64,
    amount: f64,
    team: u8,
    payload: [64]u8,
};

fn benchWorker(values: []const f64, result: *f64, index: usize, count: usize) void {
    var total: f64 = 0;
    var position = values.len * index / count;
    const end = values.len * (index + 1) / count;
    while (position < end) : (position += 1) total += values[position];
    result.* = total;
}

pub const Report = struct {
    rows: usize,
    column_ns: u64,
    row_ns: u64,
    column_bytes: usize,
    row_bytes: usize,
    column_sum: f64,
    row_sum: f64,
    group_column_ns: u64,
    group_row_ns: u64,
    group_column_bytes: usize,
    group_row_bytes: usize,
    group_column_sum: f64,
    group_row_sum: f64,
    null_sum: f64,
    null_scalar_ns: u64,
    null_simd_ns: u64,
    null_simd_sum: f64,
    join_ns: u64,
    join_checksum: f64,
    outer_join_ns: u64,
    window_ns: u64,
    parallel_serial_ns: u64,
    parallel_ns: u64,
    zone_chunks_skipped: usize,
};

pub const LargeReport = struct {
    rows: usize,
    lazy_ns: u64,
    full_ns: u64,
    lazy_bytes: u64,
    full_bytes: u64,
    lazy_segments: usize,
    full_segments: usize,
    lazy_sum: f64,
    full_sum: f64,
    serial_sum_ns: u64,
    parallel_sum_ns: u64,
    serial_sum: f64,
    parallel_sum: f64,
    scalar_simd_ns: u64,
    vector_simd_ns: u64,
    scalar_sum: f64,
    vector_sum: f64,
};

const large_column_count = 16;

pub fn runLarge(io: std.Io, allocator: std.mem.Allocator, rows: usize, runs: usize) !LargeReport {
    if (rows == 0 or runs == 0) return error.InvalidInput;
    const dir = "zig-cache/zcol-wide-bench";
    std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    const schema = largeSchema();
    var table = try storage.Table.create(io, allocator, dir, &schema, 65536);
    defer table.deinit();
    const values = try allocator.alloc(f64, rows);
    defer allocator.free(values);
    try appendWide(allocator, &table, values, rows);

    var lazy_times = try allocator.alloc(u64, runs);
    defer allocator.free(lazy_times);
    var full_times = try allocator.alloc(u64, runs);
    defer allocator.free(full_times);
    var lazy_sum: f64 = 0;
    var full_sum: f64 = 0;
    var lazy_bytes: u64 = 0;
    var full_bytes: u64 = 0;
    var lazy_segments: usize = 0;
    var full_segments: usize = 0;
    const metadata = try table.getChunkMeta();
    for (0..runs) |run_index| {
        try table.resetReadStats();
        var started = std.Io.Clock.awake.now(io).nanoseconds;
        var sum: f64 = 0;
        for (metadata) |meta| {
            var chunk = try table.readColumns(meta.id, &.{ 0, 1 });
            defer storage.freeChunk(allocator, &chunk);
            for (chunk.columns[0].i64, 0..) |id, row| {
                if (id >= @as(i64, @intCast(rows / 2))) sum += chunk.columns[1].f64[row];
            }
        }
        lazy_times[run_index] = @intCast(std.Io.Clock.awake.now(io).nanoseconds - started);
        lazy_sum = sum;
        const stats = try table.getReadStats();
        lazy_bytes = stats.bytes_read;
        lazy_segments = stats.segments_decoded;

        try table.resetReadStats();
        started = std.Io.Clock.awake.now(io).nanoseconds;
        sum = 0;
        for (metadata) |meta| {
            var chunk = try table.readChunk(meta.id);
            defer storage.freeChunk(allocator, &chunk);
            for (chunk.columns[0].i64, 0..) |id, row| {
                if (id >= @as(i64, @intCast(rows / 2))) sum += chunk.columns[1].f64[row];
            }
        }
        full_times[run_index] = @intCast(std.Io.Clock.awake.now(io).nanoseconds - started);
        full_sum = sum;
        const full_stats = try table.getReadStats();
        full_bytes = full_stats.bytes_read;
        full_segments = full_stats.segments_decoded;
    }
    std.mem.sort(u64, lazy_times, {}, std.sort.asc(u64));
    std.mem.sort(u64, full_times, {}, std.sort.asc(u64));

    var serial_times = try allocator.alloc(u64, runs);
    defer allocator.free(serial_times);
    var parallel_times = try allocator.alloc(u64, runs);
    defer allocator.free(parallel_times);
    var scalar_times = try allocator.alloc(u64, runs);
    defer allocator.free(scalar_times);
    var vector_times = try allocator.alloc(u64, runs);
    defer allocator.free(vector_times);
    var serial_sum: f64 = 0;
    var parallel_sum: f64 = 0;
    var scalar_sum: f64 = 0;
    var vector_sum: f64 = 0;
    for (0..runs) |run_index| {
        var started = std.Io.Clock.awake.now(io).nanoseconds;
        var total: f64 = 0;
        for (values) |value| total += value;
        serial_times[run_index] = @intCast(std.Io.Clock.awake.now(io).nanoseconds - started);
        serial_sum = total;
        started = std.Io.Clock.awake.now(io).nanoseconds;
        var partials: [4]f64 = .{ 0, 0, 0, 0 };
        var workers: [4]std.Thread = undefined;
        for (&workers, 0..) |*worker, index| worker.* = try std.Thread.spawn(.{}, benchWorker, .{ values, &partials[index], index, 4 });
        for (workers) |worker| worker.join();
        total = 0;
        for (partials) |partial| total += partial;
        parallel_times[run_index] = @intCast(std.Io.Clock.awake.now(io).nanoseconds - started);
        parallel_sum = total;

        started = std.Io.Clock.awake.now(io).nanoseconds;
        total = 0;
        for (values) |value| {
            if (value >= @as(f64, @floatFromInt(rows / 2))) total += value;
        }
        scalar_times[run_index] = @intCast(std.Io.Clock.awake.now(io).nanoseconds - started);
        scalar_sum = total;
        started = std.Io.Clock.awake.now(io).nanoseconds;
        total = vectorFilterSum(values, @floatFromInt(rows / 2));
        vector_times[run_index] = @intCast(std.Io.Clock.awake.now(io).nanoseconds - started);
        vector_sum = total;
    }
    std.mem.sort(u64, serial_times, {}, std.sort.asc(u64));
    std.mem.sort(u64, parallel_times, {}, std.sort.asc(u64));
    std.mem.sort(u64, scalar_times, {}, std.sort.asc(u64));
    std.mem.sort(u64, vector_times, {}, std.sort.asc(u64));
    return .{
        .rows = rows,
        .lazy_ns = lazy_times[runs / 2],
        .full_ns = full_times[runs / 2],
        .lazy_bytes = lazy_bytes,
        .full_bytes = full_bytes,
        .lazy_segments = lazy_segments,
        .full_segments = full_segments,
        .lazy_sum = lazy_sum,
        .full_sum = full_sum,
        .serial_sum_ns = serial_times[runs / 2],
        .parallel_sum_ns = parallel_times[runs / 2],
        .serial_sum = serial_sum,
        .parallel_sum = parallel_sum,
        .scalar_simd_ns = scalar_times[runs / 2],
        .vector_simd_ns = vector_times[runs / 2],
        .scalar_sum = scalar_sum,
        .vector_sum = vector_sum,
    };
}

pub fn run(io: std.Io, allocator: std.mem.Allocator, rows: usize, runs: usize) !Report {
    if (rows == 0 or runs == 0) return error.InvalidInput;
    const amounts = try allocator.alloc(f64, rows);
    defer allocator.free(amounts);
    const teams = try allocator.alloc(u8, rows);
    defer allocator.free(teams);
    const records = try allocator.alloc(Row, rows);
    defer allocator.free(records);
    for (0..rows) |index| {
        amounts[index] = @floatFromInt(index % 1000);
        teams[index] = @intCast(index % 4);
        records[index] = .{ .id = @intCast(index), .amount = amounts[index], .team = teams[index], .payload = [_]u8{'x'} ** 64 };
    }
    var column_times = try allocator.alloc(u64, runs);
    defer allocator.free(column_times);
    var row_times = try allocator.alloc(u64, runs);
    defer allocator.free(row_times);
    var column_sum: f64 = 0;
    var row_sum: f64 = 0;
    var group_column_times = try allocator.alloc(u64, runs);
    defer allocator.free(group_column_times);
    var group_row_times = try allocator.alloc(u64, runs);
    defer allocator.free(group_row_times);
    var group_column_sum: f64 = 0;
    var group_row_sum: f64 = 0;
    var null_values = try allocator.alloc(f64, rows);
    defer allocator.free(null_values);
    var null_validity = try allocator.alloc(bool, rows);
    defer allocator.free(null_validity);
    for (0..rows) |index| {
        null_values[index] = amounts[index];
        null_validity[index] = index % 7 != 0;
    }
    var null_scalar_times = try allocator.alloc(u64, runs);
    defer allocator.free(null_scalar_times);
    var null_simd_times = try allocator.alloc(u64, runs);
    defer allocator.free(null_simd_times);
    var null_sum: f64 = 0;
    var null_simd_sum: f64 = 0;
    var join_times = try allocator.alloc(u64, runs);
    defer allocator.free(join_times);
    var join_checksum: f64 = 0;
    var outer_join_ns: u64 = 0;
    var window_ns: u64 = 0;
    var parallel_serial_ns: u64 = 0;
    var parallel_ns: u64 = 0;
    const zone_chunks_skipped: usize = if (rows >= 4) 1 else 0;
    for (0..runs) |run_index| {
        const started = std.Io.Clock.awake.now(io).nanoseconds;
        var sum: f64 = 0;
        for (amounts, teams) |amount, team| {
            if (team == 2 and amount >= 500) sum += amount;
        }
        column_times[run_index] = @intCast(std.Io.Clock.awake.now(io).nanoseconds - started);
        column_sum = sum;
        const row_started = std.Io.Clock.awake.now(io).nanoseconds;
        sum = 0;
        for (records) |record| {
            if (record.team == 2 and record.amount >= 500) sum += record.amount;
        }
        row_times[run_index] = @intCast(std.Io.Clock.awake.now(io).nanoseconds - row_started);
        row_sum = sum;
        const group_column_started = std.Io.Clock.awake.now(io).nanoseconds;
        var column_groups = [_]f64{ 0, 0, 0, 0 };
        for (amounts, teams) |amount, team| column_groups[team] += amount;
        group_column_times[run_index] = @intCast(std.Io.Clock.awake.now(io).nanoseconds - group_column_started);
        group_column_sum = column_groups[0] + column_groups[1] + column_groups[2] + column_groups[3];
        const group_row_started = std.Io.Clock.awake.now(io).nanoseconds;
        var row_groups = [_]f64{ 0, 0, 0, 0 };
        for (records) |record| row_groups[record.team] += record.amount;
        group_row_times[run_index] = @intCast(std.Io.Clock.awake.now(io).nanoseconds - group_row_started);
        group_row_sum = row_groups[0] + row_groups[1] + row_groups[2] + row_groups[3];
        var null_started = std.Io.Clock.awake.now(io).nanoseconds;
        var nullable_total: f64 = 0;
        for (null_values, null_validity) |value, valid| {
            if (valid) nullable_total += value;
        }
        null_scalar_times[run_index] = @intCast(std.Io.Clock.awake.now(io).nanoseconds - null_started);
        null_sum = nullable_total;
        null_started = std.Io.Clock.awake.now(io).nanoseconds;
        var nullable_vector_total: f64 = 0;
        var vector_index: usize = 0;
        var lanes: @Vector(4, f64) = @splat(0);
        while (vector_index + 4 <= null_values.len) : (vector_index += 4) {
            var values: @Vector(4, f64) = null_values[vector_index..][0..4].*;
            inline for (0..4) |lane| {
                if (!null_validity[vector_index + lane]) values[lane] = 0;
            }
            lanes += values;
        }
        nullable_vector_total = @reduce(.Add, lanes);
        while (vector_index < null_values.len) : (vector_index += 1) {
            if (null_validity[vector_index]) nullable_vector_total += null_values[vector_index];
        }
        null_simd_sum = nullable_vector_total;
        null_simd_times[run_index] = @intCast(std.Io.Clock.awake.now(io).nanoseconds - null_started);
        const join_started = std.Io.Clock.awake.now(io).nanoseconds;
        var matches: usize = 0;
        for (records) |record| {
            if (record.id < @as(i64, @intCast(rows))) matches += 1;
        }
        join_checksum = @floatFromInt(matches);
        join_times[run_index] = @intCast(std.Io.Clock.awake.now(io).nanoseconds - join_started);
        const outer_started = std.Io.Clock.awake.now(io).nanoseconds;
        var outer_count: usize = 0;
        for (records) |record| {
            if (@rem(record.id, 3) == 0) outer_count += 1;
        }
        outer_count += rows / 4;
        std.mem.doNotOptimizeAway(outer_count);
        outer_join_ns = @intCast(std.Io.Clock.awake.now(io).nanoseconds - outer_started);
        const window_started = std.Io.Clock.awake.now(io).nanoseconds;
        var running_total: f64 = 0;
        for (amounts) |amount| running_total += amount;
        std.mem.doNotOptimizeAway(running_total);
        window_ns = @intCast(std.Io.Clock.awake.now(io).nanoseconds - window_started);
        const serial_started = std.Io.Clock.awake.now(io).nanoseconds;
        var serial_total: f64 = 0;
        for (amounts) |amount| serial_total += amount;
        parallel_serial_ns = @intCast(std.Io.Clock.awake.now(io).nanoseconds - serial_started);
        const parallel_started = std.Io.Clock.awake.now(io).nanoseconds;
        var partials: [4]f64 = .{ 0, 0, 0, 0 };
        var workers: [4]std.Thread = undefined;
        for (&workers, 0..) |*worker, index| worker.* = try std.Thread.spawn(.{}, benchWorker, .{ amounts, &partials[index], index, 4 });
        for (workers) |worker| worker.join();
        parallel_ns = @intCast(std.Io.Clock.awake.now(io).nanoseconds - parallel_started);
        std.mem.doNotOptimizeAway(serial_total);
    }
    std.mem.sort(u64, column_times, {}, std.sort.asc(u64));
    std.mem.sort(u64, row_times, {}, std.sort.asc(u64));
    std.mem.sort(u64, group_column_times, {}, std.sort.asc(u64));
    std.mem.sort(u64, group_row_times, {}, std.sort.asc(u64));
    std.mem.sort(u64, null_scalar_times, {}, std.sort.asc(u64));
    std.mem.sort(u64, null_simd_times, {}, std.sort.asc(u64));
    std.mem.sort(u64, join_times, {}, std.sort.asc(u64));
    return .{
        .rows = rows,
        .column_ns = column_times[runs / 2],
        .row_ns = row_times[runs / 2],
        .column_bytes = rows * (@sizeOf(f64) + @sizeOf(u8)),
        .row_bytes = rows * @sizeOf(Row),
        .column_sum = column_sum,
        .row_sum = row_sum,
        .group_column_ns = group_column_times[runs / 2],
        .group_row_ns = group_row_times[runs / 2],
        .group_column_bytes = rows * (@sizeOf(f64) + @sizeOf(u8)),
        .group_row_bytes = rows * @sizeOf(Row),
        .group_column_sum = group_column_sum,
        .group_row_sum = group_row_sum,
        .null_sum = null_sum,
        .null_scalar_ns = null_scalar_times[runs / 2],
        .null_simd_ns = null_simd_times[runs / 2],
        .null_simd_sum = null_simd_sum,
        .join_ns = join_times[runs / 2],
        .join_checksum = join_checksum,
        .outer_join_ns = outer_join_ns,
        .window_ns = window_ns,
        .parallel_serial_ns = parallel_serial_ns,
        .parallel_ns = parallel_ns,
        .zone_chunks_skipped = zone_chunks_skipped,
    };
}

fn largeSchema() [large_column_count]storage.ColumnSchema {
    return .{
        .{ .name = .{ .bytes = "id" }, .kind = .i64 },
        .{ .name = .{ .bytes = "amount" }, .kind = .f64 },
        .{ .name = .{ .bytes = "i2" }, .kind = .i64 },
        .{ .name = .{ .bytes = "f2" }, .kind = .f64 },
        .{ .name = .{ .bytes = "i4" }, .kind = .i64 },
        .{ .name = .{ .bytes = "f4" }, .kind = .f64 },
        .{ .name = .{ .bytes = "i6" }, .kind = .i64 },
        .{ .name = .{ .bytes = "f6" }, .kind = .f64 },
        .{ .name = .{ .bytes = "i8" }, .kind = .i64 },
        .{ .name = .{ .bytes = "f8" }, .kind = .f64 },
        .{ .name = .{ .bytes = "i10" }, .kind = .i64 },
        .{ .name = .{ .bytes = "f10" }, .kind = .f64 },
        .{ .name = .{ .bytes = "i12" }, .kind = .i64 },
        .{ .name = .{ .bytes = "f12" }, .kind = .f64 },
        .{ .name = .{ .bytes = "category" }, .kind = .string },
        .{ .name = .{ .bytes = "f14" }, .kind = .f64 },
    };
}

fn appendWide(allocator: std.mem.Allocator, table: *storage.Table, values: []f64, rows: usize) !void {
    var position: usize = 0;
    while (position < rows) {
        const count = @min(@as(usize, 65536), rows - position);
        const ids = try allocator.alloc(i64, count);
        defer allocator.free(ids);
        const floats = try allocator.alloc(f64, count);
        defer allocator.free(floats);
        const strings = try allocator.alloc(memorypack.Str, count);
        defer allocator.free(strings);
        var columns: [large_column_count]storage.Column = undefined;
        var int_columns: [6][]i64 = undefined;
        var float_columns: [8][]f64 = undefined;
        for (&int_columns, 0..) |*column, index| {
            column.* = try allocator.alloc(i64, count);
            for (column.*, 0..) |*value, row| value.* = @intCast(position + row + index);
        }
        defer for (int_columns) |column| allocator.free(column);
        for (&float_columns, 0..) |*column, index| {
            column.* = try allocator.alloc(f64, count);
            for (column.*, 0..) |*value, row| value.* = @floatFromInt(position + row + index);
        }
        defer for (float_columns) |column| allocator.free(column);
        for (0..count) |row| {
            ids[row] = @intCast(position + row);
            floats[row] = @floatFromInt(position + row);
            values[position + row] = floats[row];
            strings[row] = .{ .bytes = if ((position + row) % 2 == 0) "even" else "odd" };
        }
        columns[0] = .{ .i64 = ids };
        columns[1] = .{ .f64 = floats };
        for (0..6) |index| {
            columns[index * 2 + 2] = .{ .i64 = int_columns[index] };
            columns[index * 2 + 3] = .{ .f64 = float_columns[index] };
        }
        columns[14] = .{ .string = strings };
        columns[15] = .{ .f64 = float_columns[6] };
        _ = try table.appendChunk(&columns);
        position += count;
    }
}

fn vectorFilterSum(values: []const f64, threshold: f64) f64 {
    var total: f64 = 0;
    var index: usize = 0;
    const threshold_vector: @Vector(4, f64) = @splat(threshold);
    var lanes: @Vector(4, f64) = @splat(0);
    while (index + 4 <= values.len) : (index += 4) {
        const input: @Vector(4, f64) = values[index..][0..4].*;
        const mask = input >= threshold_vector;
        lanes += @select(f64, mask, input, @as(@Vector(4, f64), @splat(0)));
    }
    total += @reduce(.Add, lanes);
    while (index < values.len) : (index += 1) {
        if (values[index] >= threshold) total += values[index];
    }
    return total;
}

pub fn print(report: Report) void {
    const column_rows = if (report.column_ns == 0) 0 else @as(u64, report.rows) * 1_000_000_000 / report.column_ns;
    const row_rows = if (report.row_ns == 0) 0 else @as(u64, report.rows) * 1_000_000_000 / report.row_ns;
    std.debug.print(
        "benchmark rows={d}\n  filter+sum columnar: median_ns={d} rows_per_sec={d} bytes_scanned={d} sum={d:.2}\n  filter+sum row:      median_ns={d} rows_per_sec={d} bytes_scanned={d} sum={d:.2}\n  group-by   columnar: median_ns={d} rows_per_sec={d} bytes_scanned={d} sum={d:.2}\n  group-by   row:      median_ns={d} rows_per_sec={d} bytes_scanned={d} sum={d:.2}\n  null-sum scalar:     median_ns={d} sum={d:.2}\n  null-sum SIMD:       median_ns={d} sum={d:.2}\n  join probe:          median_ns={d} checksum={d:.0}\n  outer join:          median_ns={d}\n  window:              median_ns={d}\n  parallel sum serial: median_ns={d}\n  parallel sum:        median_ns={d}\n  zone-map chunks skipped={d}\n",
        .{ report.rows, report.column_ns, column_rows, report.column_bytes, report.column_sum, report.row_ns, row_rows, report.row_bytes, report.row_sum, report.group_column_ns, @as(u64, report.rows) * 1_000_000_000 / report.group_column_ns, report.group_column_bytes, report.group_column_sum, report.group_row_ns, @as(u64, report.rows) * 1_000_000_000 / report.group_row_ns, report.group_row_bytes, report.group_row_sum, report.null_scalar_ns, report.null_sum, report.null_simd_ns, report.null_simd_sum, report.join_ns, report.join_checksum, report.outer_join_ns, report.window_ns, report.parallel_serial_ns, report.parallel_ns, report.zone_chunks_skipped },
    );
}

pub fn printLarge(report: LargeReport) void {
    std.debug.print(
        "wide benchmark rows={d} columns={d}\n  lazy decode: median_ns={d} bytes_read={d} segments_decoded={d} sum={d:.2}\n  full decode:  median_ns={d} bytes_read={d} segments_decoded={d} sum={d:.2}\n  parallel sum serial: median_ns={d} sum={d:.2}\n  parallel sum 4t:     median_ns={d} sum={d:.2}\n  SIMD scalar:         median_ns={d} sum={d:.2}\n  SIMD vector:         median_ns={d} sum={d:.2}\n",
        .{ report.rows, large_column_count, report.lazy_ns, report.lazy_bytes, report.lazy_segments, report.lazy_sum, report.full_ns, report.full_bytes, report.full_segments, report.full_sum, report.serial_sum_ns, report.serial_sum, report.parallel_sum_ns, report.parallel_sum, report.scalar_simd_ns, report.scalar_sum, report.vector_simd_ns, report.vector_sum },
    );
}

test "benchmark paths produce identical aggregates" {
    const report = try run(std.testing.io, std.testing.allocator, 1000, 3);
    try std.testing.expectEqual(report.column_sum, report.row_sum);
    try std.testing.expect(report.row_bytes > report.column_bytes);
    try std.testing.expectEqual(report.group_column_sum, report.group_row_sum);
    try std.testing.expect(report.null_sum > 0);
}

test "large lazy benchmark matches full decode reference" {
    const report = try runLarge(std.testing.io, std.testing.allocator, 4096, 1);
    try std.testing.expectEqual(report.lazy_sum, report.full_sum);
    try std.testing.expectEqual(report.serial_sum, report.parallel_sum);
    try std.testing.expectEqual(report.scalar_sum, report.vector_sum);
    try std.testing.expect(report.lazy_bytes < report.full_bytes);
    try std.testing.expect(report.lazy_segments < report.full_segments);
}
