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
    }
    std.mem.sort(u64, column_times, {}, std.sort.asc(u64));
    std.mem.sort(u64, row_times, {}, std.sort.asc(u64));
    std.mem.sort(u64, group_column_times, {}, std.sort.asc(u64));
    std.mem.sort(u64, group_row_times, {}, std.sort.asc(u64));
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
    };
}

pub fn print(report: Report) void {
    const column_rows = if (report.column_ns == 0) 0 else @as(u64, report.rows) * 1_000_000_000 / report.column_ns;
    const row_rows = if (report.row_ns == 0) 0 else @as(u64, report.rows) * 1_000_000_000 / report.row_ns;
    std.debug.print(
        "benchmark rows={d}\n  filter+sum columnar: median_ns={d} rows_per_sec={d} bytes_scanned={d} sum={d:.2}\n  filter+sum row:      median_ns={d} rows_per_sec={d} bytes_scanned={d} sum={d:.2}\n  group-by   columnar: median_ns={d} rows_per_sec={d} bytes_scanned={d} sum={d:.2}\n  group-by   row:      median_ns={d} rows_per_sec={d} bytes_scanned={d} sum={d:.2}\n",
        .{ report.rows, report.column_ns, column_rows, report.column_bytes, report.column_sum, report.row_ns, row_rows, report.row_bytes, report.row_sum, report.group_column_ns, @as(u64, report.rows) * 1_000_000_000 / report.group_column_ns, report.group_column_bytes, report.group_column_sum, report.group_row_ns, @as(u64, report.rows) * 1_000_000_000 / report.group_row_ns, report.group_row_bytes, report.group_row_sum },
    );
}

test "benchmark paths produce identical aggregates" {
    const report = try run(std.testing.io, std.testing.allocator, 1000, 3);
    try std.testing.expectEqual(report.column_sum, report.row_sum);
    try std.testing.expect(report.row_bytes > report.column_bytes);
    try std.testing.expectEqual(report.group_column_sum, report.group_row_sum);
}
