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
    }
    std.mem.sort(u64, column_times, {}, std.sort.asc(u64));
    std.mem.sort(u64, row_times, {}, std.sort.asc(u64));
    return .{
        .rows = rows,
        .column_ns = column_times[runs / 2],
        .row_ns = row_times[runs / 2],
        .column_bytes = rows * (@sizeOf(f64) + @sizeOf(u8)),
        .row_bytes = rows * @sizeOf(Row),
        .column_sum = column_sum,
        .row_sum = row_sum,
    };
}

pub fn print(report: Report) void {
    const column_rows = if (report.column_ns == 0) 0 else @as(u64, report.rows) * 1_000_000_000 / report.column_ns;
    const row_rows = if (report.row_ns == 0) 0 else @as(u64, report.rows) * 1_000_000_000 / report.row_ns;
    std.debug.print(
        "benchmark rows={d}\n  columnar: median_ns={d} rows_per_sec={d} bytes_scanned={d} sum={d:.2}\n  row:      median_ns={d} rows_per_sec={d} bytes_scanned={d} sum={d:.2}\n",
        .{ report.rows, report.column_ns, column_rows, report.column_bytes, report.column_sum, report.row_ns, row_rows, report.row_bytes, report.row_sum },
    );
}

test "benchmark paths produce identical aggregates" {
    const report = try run(std.testing.io, std.testing.allocator, 1000, 3);
    try std.testing.expectEqual(report.column_sum, report.row_sum);
    try std.testing.expect(report.row_bytes > report.column_bytes);
}
