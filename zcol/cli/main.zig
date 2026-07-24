const std = @import("std");
const memorypack = @import("memorypack");
const storage = @import("storage");
const exec = @import("exec");
const sql = @import("sql");
const bench = @import("bench");

const InputValue = union(enum) {
    null: void,
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
    if (std.mem.indexOf(u8, text, "OVER") != null) return windowQuery(init, allocator, dir, text);
    var requested_threads: usize = 1;
    if (args.next()) |option| {
        if (!std.mem.eql(u8, option, "--threads")) return error.InvalidInput;
        requested_threads = std.fmt.parseInt(usize, args.next() orelse return error.InvalidInput, 10) catch return error.InvalidInput;
        if (requested_threads == 0) return error.InvalidInput;
    }
    var table = try storage.Table.open(init.io, allocator, dir);
    defer table.deinit();
    var plan = try sql.parse(allocator, text);
    defer plan.deinit();
    if (plan.join_table != null) return joinQuery(init, allocator, dir, &plan);
    const schema = try table.getSchema();
    var physical = try sql.bind(allocator, &plan, schema);
    defer sql.freeQuery(allocator, &physical);
    physical.threads = requested_threads;
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
    std.debug.print("chunks_scanned={d} chunks_skipped={d}\n", .{ result.chunks_scanned, result.chunks_skipped });
    std.debug.print("late_materialized_bytes_saved={d}\n", .{result.late_materialized_bytes_saved});
    std.debug.print("bytes_read={d} segments_decoded={d} full_decode_bytes={d}\n", .{ result.bytes_read, result.segments_decoded, result.full_decode_bytes });
}

fn windowQuery(init: std.process.Init, allocator: std.mem.Allocator, dir: []const u8, text: []const u8) !void {
    var plan = try sql.parseWindow(allocator, text);
    defer plan.deinit();
    var table = try storage.Table.open(init.io, allocator, dir);
    defer table.deinit();
    const schema = try table.getSchema();
    var partitions = try allocator.alloc(usize, plan.partition_by.len);
    defer allocator.free(partitions);
    for (plan.partition_by, 0..) |column, index| partitions[index] = findSchemaColumn(schema, column.bytes) orelse return error.ColumnNotFound;
    const order = findSchemaColumn(schema, plan.order_by.bytes) orelse return error.ColumnNotFound;
    var functions = try allocator.alloc(exec.WindowKind, plan.functions.len);
    defer allocator.free(functions);
    var value_column: ?usize = null;
    for (plan.functions, 0..) |function, index| {
        functions[index] = function.kind;
        if (function.value_column) |column| value_column = findSchemaColumn(schema, column.bytes) orelse return error.ColumnNotFound;
    }
    var result = try exec.executeWindow(allocator, &table, .{ .partition_by = partitions, .order_by = order, .order_desc = plan.order_desc, .value_column = value_column, .functions = functions });
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
}

fn joinQuery(init: std.process.Init, allocator: std.mem.Allocator, left_dir: []const u8, plan: *const sql.Plan) !void {
    const right_dir = plan.join_table.?.bytes;
    var left = try storage.Table.open(init.io, allocator, left_dir);
    defer left.deinit();
    var right = try storage.Table.open(init.io, allocator, right_dir);
    defer right.deinit();
    const left_schema = try left.getSchema();
    const right_schema = try right.getSchema();
    const left_key = try resolveQualified(left_schema, right_schema, plan.join_left.?.bytes);
    const right_key = try resolveQualified(right_schema, left_schema, plan.join_right.?.bytes);
    var left_keys = try allocator.alloc(usize, plan.join_left_keys.len);
    defer allocator.free(left_keys);
    var right_keys = try allocator.alloc(usize, plan.join_right_keys.len);
    defer allocator.free(right_keys);
    for (plan.join_left_keys, 0..) |key, index| left_keys[index] = try resolveQualified(left_schema, right_schema, key.bytes);
    for (plan.join_right_keys, 0..) |key, index| right_keys[index] = try resolveQualified(right_schema, left_schema, key.bytes);
    var projections = try allocator.alloc(exec.JoinProjection, plan.select.len);
    defer allocator.free(projections);
    for (plan.select, 0..) |item, index| {
        const column = item.column;
        const qualified = std.mem.indexOfScalar(u8, column.bytes, '.') != null;
        const is_right = qualified and (std.mem.startsWith(u8, column.bytes, "right.") or std.mem.startsWith(u8, column.bytes, "b."));
        const schema = if (is_right) right_schema else left_schema;
        const name = if (qualified) column.bytes[std.mem.indexOfScalar(u8, column.bytes, '.').? + 1 ..] else column.bytes;
        const column_index = findSchemaColumn(schema, name) orelse return error.ColumnNotFound;
        projections[index] = .{ .left = !is_right, .column = column_index, .name = .{ .bytes = column.bytes } };
    }
    const order = if (plan.order_by) |order_column| findProjection(projections, order_column.bytes) else null;
    var result = try exec.executeJoin(allocator, &left, &right, .{ .left_key = left_key, .right_key = right_key, .left_keys = left_keys, .right_keys = right_keys, .projection = projections, .kind = plan.join_kind, .order_by = order, .order_desc = plan.order_desc, .limit = plan.limit });
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
}

fn resolveQualified(primary: []const storage.ColumnSchema, secondary: []const storage.ColumnSchema, name: []const u8) !usize {
    const dot = std.mem.indexOfScalar(u8, name, '.') orelse return error.InvalidInput;
    const column = name[dot + 1 ..];
    return findSchemaColumn(primary, column) orelse findSchemaColumn(secondary, column) orelse error.ColumnNotFound;
}
fn findSchemaColumn(schema: []const storage.ColumnSchema, name: []const u8) ?usize {
    for (schema, 0..) |column, index| if (std.ascii.eqlIgnoreCase(column.name.bytes, name)) return index;
    return null;
}
fn findProjection(projections: []const exec.JoinProjection, name: []const u8) ?usize {
    for (projections, 0..) |projection, index| if (std.ascii.eqlIgnoreCase(projection.name.bytes, name) or std.ascii.eqlIgnoreCase(projection.name.bytes, name[name.len - @min(name.len, projection.name.bytes.len) ..])) return index;
    return null;
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
    const first = args.next() orelse "1000000";
    if (std.mem.eql(u8, first, "large")) {
        const rows = try std.fmt.parseInt(usize, args.next() orelse "1000000", 10);
        const runs = try std.fmt.parseInt(usize, args.next() orelse "3", 10);
        bench.printLarge(try bench.runLarge(init.io, allocator, rows, runs));
        return;
    }
    const rows = try std.fmt.parseInt(usize, first, 10);
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
    bench.printLarge(try bench.runLarge(init.io, allocator, 1000000, 3));
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
        if (field.len == 0 or std.ascii.eqlIgnoreCase(field, "NULL")) {
            values[index] = .{ .null = {} };
            continue;
        }
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
    var validity = try allocator.alloc([]u8, schema.len);
    defer {
        for (validity) |bitmap| allocator.free(bitmap);
        allocator.free(validity);
    }
    for (schema, 0..) |column, index| {
        validity[index] = try allocator.alloc(u8, (rows.len + 7) / 8);
        @memset(validity[index], 0);
        for (rows, 0..) |row, row_index| {
            if (row[index] != .null) validity[index][row_index / 8] |= @as(u8, 1) << @intCast(row_index % 8);
        }
        switch (column.kind) {
            .i64 => {
                var values = try allocator.alloc(i64, rows.len);
                for (rows, 0..) |row, row_index| values[row_index] = if (row[index] == .null) 0 else row[index].i64;
                columns[index] = .{ .i64 = values };
            },
            .f64 => {
                var values = try allocator.alloc(f64, rows.len);
                for (rows, 0..) |row, row_index| values[row_index] = if (row[index] == .null) 0 else row[index].f64;
                columns[index] = .{ .f64 = values };
            },
            .bool => {
                var values = try allocator.alloc(bool, rows.len);
                for (rows, 0..) |row, row_index| values[row_index] = if (row[index] == .null) false else row[index].bool;
                columns[index] = .{ .bool = values };
            },
            .string => {
                var values = try allocator.alloc(memorypack.Str, rows.len);
                for (rows, 0..) |row, row_index| values[row_index] = .{ .bytes = if (row[index] == .null) "" else row[index].string };
                columns[index] = .{ .string = values };
            },
        }
    }
    errdefer freeColumns(allocator, columns);
    _ = try table.appendChunkWithValidity(columns, validity);
    freeColumns(allocator, columns);
}

fn printValue(value: exec.Value) void {
    switch (value) {
        .null => std.debug.print("NULL", .{}),
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

test "cli parses a typed schema" {
    const schema = try parseSchema(std.testing.allocator, "id:i64,active:bool,team:string");
    defer freeSchema(std.testing.allocator, schema);
    try std.testing.expectEqual(@as(usize, 3), schema.len);
    try std.testing.expectEqual(storage.ColumnType.bool, schema[1].kind);
}
