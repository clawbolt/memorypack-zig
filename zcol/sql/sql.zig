const std = @import("std");
const memorypack = @import("memorypack");
const storage = @import("storage");
const exec = @import("exec");

pub const ParseError = error{
    EmptyQuery,
    ExpectedSelect,
    ExpectedFrom,
    MissingTable,
    InvalidProjection,
    InvalidPredicate,
    InvalidOperator,
    InvalidLiteral,
    InvalidGroupBy,
    TrailingTokens,
} || std.mem.Allocator.Error;

pub const SelectItem = union(enum) {
    column: memorypack.Str,
    aggregate: struct {
        kind: exec.AggregateKind,
        column: memorypack.Str,
    },
};
pub const Predicate = struct {
    column: memorypack.Str,
    op: exec.CompareOp,
    literal: memorypack.Str,
    null_check: ?bool = null,
};
pub const Plan = struct {
    allocator: std.mem.Allocator,
    table: memorypack.Str,
    select: []SelectItem,
    predicates: []Predicate,
    group_by: ?memorypack.Str,

    pub fn deinit(self: *Plan) void {
        self.allocator.free(self.table.bytes);
        for (self.select) |item| switch (item) {
            .column => |column| self.allocator.free(column.bytes),
            .aggregate => |aggregate| {
                self.allocator.free(aggregate.column.bytes);
            },
        };
        self.allocator.free(self.select);
        for (self.predicates) |predicate| {
            self.allocator.free(predicate.column.bytes);
            self.allocator.free(predicate.literal.bytes);
        }
        self.allocator.free(self.predicates);
        if (self.group_by) |group| self.allocator.free(group.bytes);
    }
};

pub fn parse(allocator: std.mem.Allocator, text: []const u8) ParseError!Plan {
    var tokens = std.mem.tokenizeAny(u8, text, " \t\r\n");
    const first = tokens.next() orelse return error.EmptyQuery;
    if (!std.ascii.eqlIgnoreCase(first, "SELECT")) return error.ExpectedSelect;
    var select: std.ArrayList(SelectItem) = .empty;
    errdefer freeSelectList(allocator, &select);
    var token = tokens.next() orelse return error.ExpectedFrom;
    while (!std.ascii.eqlIgnoreCase(stripComma(token), "FROM")) {
        const item = stripComma(token);
        if (item.len == 0) return error.InvalidProjection;
        try select.append(allocator, try parseSelectItem(allocator, item));
        token = tokens.next() orelse return error.ExpectedFrom;
    }
    const table = tokens.next() orelse return error.MissingTable;
    var predicates: std.ArrayList(Predicate) = .empty;
    errdefer freePredicateList(allocator, &predicates);
    var group_by: ?memorypack.Str = null;
    if (tokens.next()) |keyword| {
        if (std.ascii.eqlIgnoreCase(keyword, "WHERE")) {
            while (true) {
                const column = tokens.next() orelse return error.InvalidPredicate;
                const operator = tokens.next() orelse return error.InvalidOperator;
                if (std.ascii.eqlIgnoreCase(operator, "IS")) {
                    const maybe_not = tokens.next() orelse return error.InvalidLiteral;
                    var is_null = true;
                    var consumed = maybe_not;
                    if (std.ascii.eqlIgnoreCase(maybe_not, "NOT")) {
                        is_null = false;
                        consumed = tokens.next() orelse return error.InvalidLiteral;
                    }
                    if (!std.ascii.eqlIgnoreCase(consumed, "NULL")) return error.InvalidLiteral;
                    try predicates.append(allocator, .{ .column = .{ .bytes = try allocator.dupe(u8, stripComma(column)) }, .op = .eq, .literal = .{ .bytes = try allocator.dupe(u8, "") }, .null_check = is_null });
                    const next = tokens.next() orelse break;
                    if (!std.ascii.eqlIgnoreCase(next, "AND")) return error.TrailingTokens;
                    continue;
                }
                const literal = tokens.next() orelse return error.InvalidLiteral;
                const op = try parseOperator(operator);
                const column_copy = try allocator.dupe(u8, stripComma(column));
                errdefer allocator.free(column_copy);
                const literal_copy = try allocator.dupe(u8, stripCommaQuotes(literal));
                errdefer allocator.free(literal_copy);
                try predicates.append(allocator, .{
                    .column = .{ .bytes = column_copy },
                    .op = op,
                    .literal = .{ .bytes = literal_copy },
                });
                const next = tokens.next() orelse break;
                if (!std.ascii.eqlIgnoreCase(next, "AND")) {
                    if (!std.ascii.eqlIgnoreCase(next, "GROUP")) return error.TrailingTokens;
                    const by = tokens.next() orelse return error.InvalidGroupBy;
                    if (!std.ascii.eqlIgnoreCase(by, "BY")) return error.InvalidGroupBy;
                    const group = tokens.next() orelse return error.InvalidGroupBy;
                    group_by = .{ .bytes = try allocator.dupe(u8, stripComma(group)) };
                    if (tokens.next() != null) return error.TrailingTokens;
                    break;
                }
            }
        } else if (std.ascii.eqlIgnoreCase(keyword, "GROUP")) {
            const by = tokens.next() orelse return error.InvalidGroupBy;
            if (!std.ascii.eqlIgnoreCase(by, "BY")) return error.InvalidGroupBy;
            const group = tokens.next() orelse return error.InvalidGroupBy;
            group_by = .{ .bytes = try allocator.dupe(u8, stripComma(group)) };
            if (tokens.next() != null) return error.TrailingTokens;
        } else return error.TrailingTokens;
    }
    return .{
        .allocator = allocator,
        .table = .{ .bytes = try allocator.dupe(u8, table) },
        .select = try select.toOwnedSlice(allocator),
        .predicates = try predicates.toOwnedSlice(allocator),
        .group_by = group_by,
    };
}

pub fn bind(allocator: std.mem.Allocator, plan: *const Plan, schema: []const storage.ColumnSchema) !exec.Query {
    var projection: std.ArrayList(usize) = .empty;
    errdefer projection.deinit(allocator);
    var aggregates: std.ArrayList(exec.Aggregate) = .empty;
    errdefer aggregates.deinit(allocator);
    for (plan.select) |item| switch (item) {
        .column => |column| try projection.append(allocator, findColumn(schema, column.bytes) orelse return error.ColumnNotFound),
        .aggregate => |aggregate| {
            const column = if (std.mem.eql(u8, aggregate.column.bytes, "*")) null else findColumn(schema, aggregate.column.bytes) orelse return error.ColumnNotFound;
            try aggregates.append(allocator, .{ .kind = aggregate.kind, .column = column });
        },
    };
    var predicates: std.ArrayList(exec.Predicate) = .empty;
    errdefer freeBoundPredicates(allocator, predicates.items);
    for (plan.predicates) |predicate| {
        const column = findColumn(schema, predicate.column.bytes) orelse return error.ColumnNotFound;
        try predicates.append(allocator, .{ .column = column, .op = predicate.op, .value = if (predicate.null_check != null) .{ .null = {} } else try parseScalar(allocator, schema[column].kind, predicate.literal.bytes), .null_check = predicate.null_check });
    }
    const group_by = if (plan.group_by) |group| findColumn(schema, group.bytes) orelse return error.ColumnNotFound else null;
    return .{
        .projection = try projection.toOwnedSlice(allocator),
        .predicates = try predicates.toOwnedSlice(allocator),
        .aggregates = try aggregates.toOwnedSlice(allocator),
        .group_by = group_by,
    };
}

pub fn freeQuery(allocator: std.mem.Allocator, query: *exec.Query) void {
    allocator.free(query.projection);
    for (query.predicates) |predicate| freeScalar(allocator, predicate.value);
    allocator.free(query.predicates);
    allocator.free(query.aggregates);
}

fn parseSelectItem(allocator: std.mem.Allocator, token: []const u8) !SelectItem {
    if (std.mem.indexOfScalar(u8, token, '(')) |open| {
        if (token[token.len - 1] != ')') return error.InvalidProjection;
        const function = token[0..open];
        const argument = token[open + 1 .. token.len - 1];
        var kind: exec.AggregateKind = undefined;
        if (std.ascii.eqlIgnoreCase(function, "COUNT")) kind = .count else if (std.ascii.eqlIgnoreCase(function, "SUM")) kind = .sum else if (std.ascii.eqlIgnoreCase(function, "MIN")) kind = .min else if (std.ascii.eqlIgnoreCase(function, "MAX")) kind = .max else if (std.ascii.eqlIgnoreCase(function, "AVG")) kind = .avg else return error.InvalidProjection;
        if (argument.len == 0) return error.InvalidProjection;
        return .{ .aggregate = .{ .kind = kind, .column = .{ .bytes = try allocator.dupe(u8, argument) } } };
    }
    return .{ .column = .{ .bytes = try allocator.dupe(u8, token) } };
}

fn parseOperator(token: []const u8) !exec.CompareOp {
    return if (std.mem.eql(u8, token, "=")) .eq else if (std.mem.eql(u8, token, "<")) .lt else if (std.mem.eql(u8, token, "<=")) .lte else if (std.mem.eql(u8, token, ">")) .gt else if (std.mem.eql(u8, token, ">=")) .gte else if (std.mem.eql(u8, token, "!=")) .neq else error.InvalidOperator;
}

fn parseScalar(allocator: std.mem.Allocator, kind: storage.ColumnType, literal: []const u8) !exec.Scalar {
    return switch (kind) {
        .i64 => .{ .i64 = std.fmt.parseInt(i64, literal, 10) catch return error.InvalidLiteral },
        .f64 => .{ .f64 = std.fmt.parseFloat(f64, literal) catch return error.InvalidLiteral },
        .bool => .{ .bool = if (std.ascii.eqlIgnoreCase(literal, "true")) true else if (std.ascii.eqlIgnoreCase(literal, "false")) false else return error.InvalidLiteral },
        .string => .{ .string = .{ .bytes = try allocator.dupe(u8, literal) } },
    };
}

fn findColumn(schema: []const storage.ColumnSchema, name: []const u8) ?usize {
    for (schema, 0..) |column, index| if (std.ascii.eqlIgnoreCase(column.name.bytes, name)) return index;
    return null;
}
fn stripComma(token: []const u8) []const u8 {
    return if (token.len > 0 and token[token.len - 1] == ',') token[0 .. token.len - 1] else token;
}
fn stripCommaQuotes(token: []const u8) []const u8 {
    const value = stripComma(token);
    if (value.len >= 2 and ((value[0] == '\'' and value[value.len - 1] == '\'') or (value[0] == '"' and value[value.len - 1] == '"'))) return value[1 .. value.len - 1];
    return value;
}
fn freeSelect(allocator: std.mem.Allocator, items: []SelectItem) void {
    for (items) |item| switch (item) {
        .column => |column| allocator.free(column.bytes),
        .aggregate => |aggregate| allocator.free(aggregate.column.bytes),
    };
    allocator.free(items);
}
fn freeSelectList(allocator: std.mem.Allocator, items: *std.ArrayList(SelectItem)) void {
    for (items.items) |item| switch (item) {
        .column => |column| allocator.free(column.bytes),
        .aggregate => |aggregate| allocator.free(aggregate.column.bytes),
    };
    items.deinit(allocator);
}
fn freePredicates(allocator: std.mem.Allocator, predicates: []Predicate) void {
    for (predicates) |predicate| {
        allocator.free(predicate.column.bytes);
        allocator.free(predicate.literal.bytes);
    }
    allocator.free(predicates);
}
fn freePredicateList(allocator: std.mem.Allocator, predicates: *std.ArrayList(Predicate)) void {
    for (predicates.items) |predicate| {
        allocator.free(predicate.column.bytes);
        allocator.free(predicate.literal.bytes);
    }
    predicates.deinit(allocator);
}
fn freeBoundPredicates(allocator: std.mem.Allocator, predicates: []exec.Predicate) void {
    for (predicates) |predicate| freeScalar(allocator, predicate.value);
    allocator.free(predicates);
}
fn freeScalar(allocator: std.mem.Allocator, scalar: exec.Scalar) void {
    if (scalar == .string) allocator.free(scalar.string.bytes);
}

test "sql parser binds filters and aggregates" {
    const allocator = std.testing.allocator;
    var plan = try parse(allocator, "SELECT team, SUM(amount) FROM sales WHERE amount >= 20 GROUP BY team");
    defer plan.deinit();
    const schema = [_]storage.ColumnSchema{
        .{ .name = .{ .bytes = "amount" }, .kind = .f64 },
        .{ .name = .{ .bytes = "team" }, .kind = .string },
    };
    var query = try bind(allocator, &plan, &schema);
    defer freeQuery(allocator, &query);
    try std.testing.expectEqual(@as(usize, 1), query.predicates.len);
    try std.testing.expectEqual(@as(usize, 1), query.aggregates.len);
    try std.testing.expectEqual(@as(usize, 1), query.group_by.?);
}

test "sql parser rejects malformed input" {
    try std.testing.expectError(error.ExpectedSelect, parse(std.testing.allocator, "DELETE FROM sales"));
    try std.testing.expectError(error.InvalidOperator, parse(std.testing.allocator, "SELECT amount FROM sales WHERE amount ~~ 2"));
}
