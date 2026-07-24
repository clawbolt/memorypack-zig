const std = @import("std");

pub const Row = struct {
    id: i64,
    amount: f64,
    team: u8,
    payload: [64]u8,
};

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
};

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
    };
}

pub fn print(report: Report) void {
    const column_rows = if (report.column_ns == 0) 0 else @as(u64, report.rows) * 1_000_000_000 / report.column_ns;
    const row_rows = if (report.row_ns == 0) 0 else @as(u64, report.rows) * 1_000_000_000 / report.row_ns;
    std.debug.print(
        "benchmark rows={d}\n  filter+sum columnar: median_ns={d} rows_per_sec={d} bytes_scanned={d} sum={d:.2}\n  filter+sum row:      median_ns={d} rows_per_sec={d} bytes_scanned={d} sum={d:.2}\n  group-by   columnar: median_ns={d} rows_per_sec={d} bytes_scanned={d} sum={d:.2}\n  group-by   row:      median_ns={d} rows_per_sec={d} bytes_scanned={d} sum={d:.2}\n  null-sum scalar:     median_ns={d} sum={d:.2}\n  null-sum SIMD:       median_ns={d} sum={d:.2}\n  join probe:          median_ns={d} checksum={d:.0}\n",
        .{ report.rows, report.column_ns, column_rows, report.column_bytes, report.column_sum, report.row_ns, row_rows, report.row_bytes, report.row_sum, report.group_column_ns, @as(u64, report.rows) * 1_000_000_000 / report.group_column_ns, report.group_column_bytes, report.group_column_sum, report.group_row_ns, @as(u64, report.rows) * 1_000_000_000 / report.group_row_ns, report.group_row_bytes, report.group_row_sum, report.null_scalar_ns, report.null_sum, report.null_simd_ns, report.null_simd_sum, report.join_ns, report.join_checksum },
    );
}

test "benchmark paths produce identical aggregates" {
    const report = try run(std.testing.io, std.testing.allocator, 1000, 3);
    try std.testing.expectEqual(report.column_sum, report.row_sum);
    try std.testing.expect(report.row_bytes > report.column_bytes);
    try std.testing.expectEqual(report.group_column_sum, report.group_row_sum);
    try std.testing.expect(report.null_sum > 0);
}
