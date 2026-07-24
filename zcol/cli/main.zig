const std = @import("std");
const memorypack = @import("memorypack");
const storage = @import("storage");
const exec = @import("exec");
const sql = @import("sql");
const bench = @import("bench");

const InputValue = union(enum) {
    i64: i64,
    f64: f64,
    bool: bool,
    string: []u8,
};

pub fn main(init: std.process.Init) !void {
    var args = try init.minimal.args.iterateAllocator(init.gpa);
    defer args.deinit();
    _ = args.next();
    const command = args.next() orelse return error.InvalidInput;
    if (std.mem.eql(u8, command, "create-table")) return createTable(init, init.gpa, &args);
    if (std.mem.eql(u8, command, "load")) return load(init, init.gpa, &args);
    if (std.mem.eql(u8, command, "query")) return query(init, init.gpa, &args);
    if (std.mem.eql(u8, command, "describe")) return describe(init, init.gpa, &args);
    if (std.mem.eql(u8, command, "stats")) return stats(init, init.gpa, &args);
    if (std.mem.eql(u8, command, "benchmark")) return benchmarkCommand(init, init.gpa, &args);
    if (std.mem.eql(u8, command, "demo")) return demo(init, init.gpa, &args);
    return error.InvalidInput;
}

fn createTable(init: std.process.Init, allocator: std.mem.Allocator, args: *std.process.Args.Iterator) !void {
    const dir = args.next() orelse return error.InvalidInput;
    const schema_text = flag(args, "--schema", "id:i64,amount:f64,active:bool,team:string");
    const chunk_rows = try std.fmt.parseInt(u32, flag(args, "--chunk-rows", "65536"), 10);
    const schema = try parseSchema(allocator, schema_text);
    defer freeSchema(allocator, schema);
    var table = try storage.Table.create(init.io, allocator, dir, schema, chunk_rows);
    defer table.deinit();
    std.debug.print("created table dir={s} columns={d} chunk_rows={d}\n", .{ dir, schema.len, chunk_rows });
}

fn load(init: std.process.Init, allocator: std.mem.Allocator, args: *std.process.Args.Iterator) !void {
    const dir = args.next() orelse return error.InvalidInput;
    const file_path = args.next() orelse return error.InvalidInput;
    var table = try storage.Table.open(init.io, allocator, dir);
    defer table.deinit();
    const schema = try table.getSchema();
    const contents = try std.Io.Dir.cwd().readFileAlloc(init.io, file_path, allocator, .limited(1024 * 1024 * 1024));
    defer allocator.free(contents);
    var rows: std.ArrayList([]InputValue) = .empty;
    defer {
        freeInputRows(allocator, rows.items);
        rows.deinit(allocator);
    }
    var lines = std.mem.splitScalar(u8, contents, '\n');
    _ = lines.next();
    var chunks: usize = 0;
    var total: usize = 0;
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \r\t");
        if (trimmed.len == 0) continue;
        try rows.append(allocator, try parseRow(allocator, schema, trimmed));
        if (rows.items.len == table.chunk_rows) {
            try flushRows(allocator, &table, schema, rows.items);
            total += rows.items.len;
            chunks += 1;
            freeInputRows(allocator, rows.items);
            rows.clearRetainingCapacity();
        }
    }
    if (rows.items.len > 0) {
        try flushRows(allocator, &table, schema, rows.items);
        total += rows.items.len;
        chunks += 1;
    }
    std.debug.print("loaded rows={d} chunks={d}\n", .{ total, chunks });
}

fn query(init: std.process.Init, allocator: std.mem.Allocator, args: *std.process.Args.Iterator) !void {
    const dir = args.next() orelse return error.InvalidInput;
    const text = args.next() orelse return error.InvalidInput;
    var table = try storage.Table.open(init.io, allocator, dir);
    defer table.deinit();
    var plan = try sql.parse(allocator, text);
    defer plan.deinit();
    const schema = try table.getSchema();
    var physical = try sql.bind(allocator, &plan, schema);
    defer sql.freeQuery(allocator, &physical);
    var result = try exec.execute(allocator, &table, physical);
    defer result.deinit();
    for (result.columns) |column| std.debug.print("{s}\t", .{column.bytes});
    std.debug.print("\n", .{});
    for (result.rows) |row| {
        for (row) |value| {
            printValue(value);
            std.debug.print("\t", .{});
        }
        std.debug.print("\n", .{});
    }
    std.debug.print("rows={d}\n", .{result.rows.len});
}

fn describe(init: std.process.Init, allocator: std.mem.Allocator, args: *std.process.Args.Iterator) !void {
    const dir = args.next() orelse return error.InvalidInput;
    var table = try storage.Table.open(init.io, allocator, dir);
    defer table.deinit();
    for (try table.getSchema()) |column| std.debug.print("{s}\t{t}\n", .{ column.name.bytes, column.kind });
}

fn stats(init: std.process.Init, allocator: std.mem.Allocator, args: *std.process.Args.Iterator) !void {
    const dir = args.next() orelse return error.InvalidInput;
    var table = try storage.Table.open(init.io, allocator, dir);
    defer table.deinit();
    const value = try table.stats();
    std.debug.print("columns={d} chunks={d} rows={d} bytes={d}\n", .{ value.columns, value.chunks, value.rows, value.bytes });
}

fn benchmarkCommand(init: std.process.Init, allocator: std.mem.Allocator, args: *std.process.Args.Iterator) !void {
    const rows = try std.fmt.parseInt(usize, args.next() orelse "1000000", 10);
    const report = try bench.run(init.io, allocator, rows, 7);
    bench.print(report);
}

fn demo(init: std.process.Init, allocator: std.mem.Allocator, args: *std.process.Args.Iterator) !void {
    const dir = args.next() orelse return error.InvalidInput;
    const csv = try std.fmt.allocPrint(allocator, "{s}/sample.csv", .{dir});
    defer allocator.free(csv);
    try std.Io.Dir.cwd().createDirPath(init.io, dir);
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = csv, .data = "id,amount,active,team\n1,10,true,alpha\n2,20,true,alpha\n3,30,false,beta\n4,40,true,beta\n" });
    const schema = [_]storage.ColumnSchema{
        .{ .name = .{ .bytes = "id" }, .kind = .i64 },
        .{ .name = .{ .bytes = "amount" }, .kind = .f64 },
        .{ .name = .{ .bytes = "active" }, .kind = .bool },
        .{ .name = .{ .bytes = "team" }, .kind = .string },
    };
    var table = try storage.Table.create(init.io, allocator, dir, &schema, 64);
    table.deinit();
    try loadFile(init, allocator, dir, csv);
    try runQuery(init, allocator, dir, "SELECT amount, team FROM sales WHERE amount >= 20");
    try runQuery(init, allocator, dir, "SELECT SUM(amount), COUNT(*) FROM sales WHERE active = true");
    try runQuery(init, allocator, dir, "SELECT team, SUM(amount), COUNT(*) FROM sales GROUP BY team");
    const report = try bench.run(init.io, allocator, 100000, 7);
    bench.print(report);
}

fn loadFile(init: std.process.Init, allocator: std.mem.Allocator, dir: []const u8, file_path: []const u8) !void {
    var table = try storage.Table.open(init.io, allocator, dir);
    defer table.deinit();
    const schema = try table.getSchema();
    const contents = try std.Io.Dir.cwd().readFileAlloc(init.io, file_path, allocator, .limited(1024 * 1024 * 1024));
    defer allocator.free(contents);
    var lines = std.mem.splitScalar(u8, contents, '\n');
    _ = lines.next();
    var rows: std.ArrayList([]InputValue) = .empty;
    defer {
        freeInputRows(allocator, rows.items);
        rows.deinit(allocator);
    }
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \r\t");
        if (trimmed.len == 0) continue;
        try rows.append(allocator, try parseRow(allocator, schema, trimmed));
    }
    try flushRows(allocator, &table, schema, rows.items);
}

fn runQuery(init: std.process.Init, allocator: std.mem.Allocator, dir: []const u8, text: []const u8) !void {
    std.debug.print("\nSQL> {s}\n", .{text});
    var table = try storage.Table.open(init.io, allocator, dir);
    defer table.deinit();
    var plan = try sql.parse(allocator, text);
    defer plan.deinit();
    var physical = try sql.bind(allocator, &plan, try table.getSchema());
    defer sql.freeQuery(allocator, &physical);
    var result = try exec.execute(allocator, &table, physical);
    defer result.deinit();
    for (result.rows) |row| {
        for (row) |value| {
            printValue(value);
            std.debug.print("\t", .{});
        }
        std.debug.print("\n", .{});
    }
}

fn parseSchema(allocator: std.mem.Allocator, text: []const u8) ![]storage.ColumnSchema {
    var result: std.ArrayList(storage.ColumnSchema) = .empty;
    errdefer freeSchema(allocator, result.items);
    var tokens = std.mem.splitScalar(u8, text, ',');
    while (tokens.next()) |token| {
        var parts = std.mem.splitScalar(u8, token, ':');
        const name = parts.next() orelse return error.InvalidSchema;
        const kind_text = parts.next() orelse return error.InvalidSchema;
        var kind: storage.ColumnType = undefined;
        if (std.mem.eql(u8, kind_text, "i64")) kind = .i64 else if (std.mem.eql(u8, kind_text, "f64")) kind = .f64 else if (std.mem.eql(u8, kind_text, "bool")) kind = .bool else if (std.mem.eql(u8, kind_text, "string")) kind = .string else return error.InvalidSchema;
        try result.append(allocator, .{ .name = .{ .bytes = try allocator.dupe(u8, name) }, .kind = kind });
    }
    return result.toOwnedSlice(allocator);
}

fn parseRow(allocator: std.mem.Allocator, schema: []const storage.ColumnSchema, line: []const u8) ![]InputValue {
    var values = try allocator.alloc(InputValue, schema.len);
    errdefer freeInputValues(allocator, values);
    var fields = std.mem.splitScalar(u8, line, ',');
    for (schema, 0..) |column, index| {
        const field = fields.next() orelse return error.InvalidRow;
        values[index] = switch (column.kind) {
            .i64 => .{ .i64 = std.fmt.parseInt(i64, field, 10) catch return error.InvalidRow },
            .f64 => .{ .f64 = std.fmt.parseFloat(f64, field) catch return error.InvalidRow },
            .bool => .{ .bool = if (std.mem.eql(u8, field, "true")) true else if (std.mem.eql(u8, field, "false")) false else return error.InvalidRow },
            .string => .{ .string = try allocator.dupe(u8, field) },
        };
    }
    return values;
}

fn flushRows(allocator: std.mem.Allocator, table: *storage.Table, schema: []const storage.ColumnSchema, rows: []const []InputValue) !void {
    var columns = try allocator.alloc(storage.Column, schema.len);
    defer allocator.free(columns);
    for (schema, 0..) |column, index| {
        switch (column.kind) {
            .i64 => {
                var values = try allocator.alloc(i64, rows.len);
                for (rows, 0..) |row, row_index| values[row_index] = row[index].i64;
                columns[index] = .{ .i64 = values };
            },
            .f64 => {
                var values = try allocator.alloc(f64, rows.len);
                for (rows, 0..) |row, row_index| values[row_index] = row[index].f64;
                columns[index] = .{ .f64 = values };
            },
            .bool => {
                var values = try allocator.alloc(bool, rows.len);
                for (rows, 0..) |row, row_index| values[row_index] = row[index].bool;
                columns[index] = .{ .bool = values };
            },
            .string => {
                var values = try allocator.alloc(memorypack.Str, rows.len);
                for (rows, 0..) |row, row_index| values[row_index] = .{ .bytes = row[index].string };
                columns[index] = .{ .string = values };
            },
        }
    }
    errdefer freeColumns(allocator, columns);
    _ = try table.appendChunk(columns);
    freeColumns(allocator, columns);
}

fn printValue(value: exec.Value) void {
    switch (value) {
        .i64 => |number| std.debug.print("{d}", .{number}),
        .f64 => |number| std.debug.print("{d:.2}", .{number}),
        .bool => |flag_value| std.debug.print("{}", .{flag_value}),
        .string => |text| std.debug.print("{s}", .{text.bytes}),
    }
}
fn flag(args: *std.process.Args.Iterator, name: []const u8, fallback: []const u8) []const u8 {
    var copy = args.*;
    while (copy.next()) |value| if (std.mem.eql(u8, value, name)) return copy.next() orelse fallback;
    return fallback;
}
fn freeSchema(allocator: std.mem.Allocator, schema: []storage.ColumnSchema) void {
    for (schema) |column| allocator.free(column.name.bytes);
    allocator.free(schema);
}
fn freeInputValues(allocator: std.mem.Allocator, values: []InputValue) void {
    for (values) |value| if (value == .string) allocator.free(value.string);
    allocator.free(values);
}
fn freeInputRows(allocator: std.mem.Allocator, rows: []([]InputValue)) void {
    for (rows) |row| freeInputValues(allocator, row);
}
fn freeColumns(allocator: std.mem.Allocator, columns: []storage.Column) void {
    for (columns) |column| switch (column) {
        .i64 => |values| allocator.free(values),
        .f64 => |values| allocator.free(values),
        .bool => |values| allocator.free(values),
        .string => |values| allocator.free(values),
    };
}
