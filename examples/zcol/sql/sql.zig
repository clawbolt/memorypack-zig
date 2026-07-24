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
    InvalidLimit,
    TrailingTokens,
} || std.mem.Allocator.Error;

pub const SelectItem = union(enum) {
    column: memorypack.Str,
    aggregate: struct {
        kind: exec.AggregateKind,
        column: memorypack.Str,
    },
};
pub const WindowFunction = struct {
    kind: exec.WindowKind,
    value_column: ?memorypack.Str = null,
};
pub const WindowPlan = struct {
    allocator: std.mem.Allocator,
    table: memorypack.Str,
    projection: []memorypack.Str,
    partition_by: []memorypack.Str,
    order_by: memorypack.Str,
    order_desc: bool,
    functions: []WindowFunction,

    pub fn deinit(self: *WindowPlan) void {
        self.allocator.free(self.table.bytes);
        for (self.projection) |column| self.allocator.free(column.bytes);
        self.allocator.free(self.projection);
        for (self.partition_by) |column| self.allocator.free(column.bytes);
        self.allocator.free(self.partition_by);
        self.allocator.free(self.order_by.bytes);
        for (self.functions) |function| if (function.value_column) |column| self.allocator.free(column.bytes);
        self.allocator.free(self.functions);
    }
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
    group_by_columns: []memorypack.Str,
    order_by: ?memorypack.Str,
    order_desc: bool,
    limit: ?usize,
    join_table: ?memorypack.Str = null,
    join_left: ?memorypack.Str = null,
    join_right: ?memorypack.Str = null,
    join_left_keys: []memorypack.Str = &.{},
    join_right_keys: []memorypack.Str = &.{},
    join_kind: exec.JoinKind = .inner,
    threads: usize = 1,

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
        for (self.group_by_columns) |group| self.allocator.free(group.bytes);
        self.allocator.free(self.group_by_columns);
        if (self.order_by) |order| self.allocator.free(order.bytes);
        if (self.join_table) |join| self.allocator.free(join.bytes);
        if (self.join_left) |join| self.allocator.free(join.bytes);
        if (self.join_right) |join| self.allocator.free(join.bytes);
        for (self.join_left_keys) |key| self.allocator.free(key.bytes);
        self.allocator.free(self.join_left_keys);
        for (self.join_right_keys) |key| self.allocator.free(key.bytes);
        self.allocator.free(self.join_right_keys);
    }
};

pub fn parseWindow(allocator: std.mem.Allocator, text: []const u8) ParseError!WindowPlan {
    const from_marker = std.mem.indexOf(u8, text, " FROM ") orelse return error.ExpectedFrom;
    const select_text = text[7..from_marker];
    const table_text = text[from_marker + 6 ..];
    const over_marker = std.mem.indexOf(u8, select_text, " OVER ") orelse return error.InvalidProjection;
    const over_text = select_text[over_marker + 6 ..];
    const partition_marker = std.mem.indexOf(u8, over_text, "PARTITION BY ") orelse return error.InvalidProjection;
    const order_marker = std.mem.indexOf(u8, over_text, " ORDER BY ") orelse return error.InvalidProjection;
    const partition_text = over_text[partition_marker + 13 .. order_marker];
    const order_text = over_text[order_marker + 10 ..];
    const close = std.mem.indexOfScalar(u8, order_text, ')') orelse order_text.len;
    var order_name = std.mem.trim(u8, order_text[0..close], " ()");
    var order_desc = false;
    if (std.ascii.endsWithIgnoreCase(order_name, " DESC")) {
        order_desc = true;
        order_name = std.mem.trim(u8, order_name[0 .. order_name.len - 5], " ");
    } else if (std.ascii.endsWithIgnoreCase(order_name, " ASC")) {
        order_name = std.mem.trim(u8, order_name[0 .. order_name.len - 4], " ");
    }
    var projection: std.ArrayList(memorypack.Str) = .empty;
    var partition: std.ArrayList(memorypack.Str) = .empty;
    var functions: std.ArrayList(WindowFunction) = .empty;
    errdefer {
        for (projection.items) |column| allocator.free(column.bytes);
        projection.deinit(allocator);
        for (partition.items) |column| allocator.free(column.bytes);
        partition.deinit(allocator);
        for (functions.items) |function| if (function.value_column) |column| allocator.free(column.bytes);
        functions.deinit(allocator);
    }
    var select_tokens = std.mem.splitSequence(u8, select_text[0..over_marker], ",");
    while (select_tokens.next()) |token| {
        const name = std.mem.trim(u8, token, " \t\r\n");
        if (name.len > 0) try projection.append(allocator, .{ .bytes = try allocator.dupe(u8, name) });
    }
    var partition_tokens = std.mem.splitSequence(u8, partition_text, ",");
    while (partition_tokens.next()) |token| {
        const name = std.mem.trim(u8, token, " \t\r\n");
        if (name.len > 0) try partition.append(allocator, .{ .bytes = try allocator.dupe(u8, name) });
    }
    if (std.mem.indexOf(u8, select_text, "ROW_NUMBER()") != null) try functions.append(allocator, .{ .kind = .row_number });
    if (std.mem.indexOf(u8, select_text, "RANK()") != null) try functions.append(allocator, .{ .kind = .rank });
    if (std.mem.indexOf(u8, select_text, "DENSE_RANK()") != null) try functions.append(allocator, .{ .kind = .dense_rank });
    for ([_]struct { marker: []const u8, kind: exec.WindowKind }{
        .{ .marker = "SUM(", .kind = .running_sum },
        .{ .marker = "AVG(", .kind = .running_avg },
        .{ .marker = "COUNT(", .kind = .running_count },
    }) |entry| if (std.mem.indexOf(u8, select_text, entry.marker)) |start| {
        const end = std.mem.indexOfScalarPos(u8, select_text, start + entry.marker.len, ')') orelse return error.InvalidProjection;
        try functions.append(allocator, .{ .kind = entry.kind, .value_column = .{ .bytes = try allocator.dupe(u8, std.mem.trim(u8, select_text[start + entry.marker.len .. end], " \t")) } });
    };
    return .{
        .allocator = allocator,
        .table = .{ .bytes = try allocator.dupe(u8, std.mem.trim(u8, table_text, " \t\r\n")) },
        .projection = try projection.toOwnedSlice(allocator),
        .partition_by = try partition.toOwnedSlice(allocator),
        .order_by = .{ .bytes = try allocator.dupe(u8, order_name) },
        .order_desc = order_desc,
        .functions = try functions.toOwnedSlice(allocator),
    };
}

pub fn parse(allocator: std.mem.Allocator, text: []const u8) ParseError!Plan {
    if (std.mem.indexOf(u8, text, " JOIN ") != null) return parseJoin(allocator, text);
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
    const group_by: ?memorypack.Str = null;
    var group_columns: std.ArrayList(memorypack.Str) = .empty;
    var order_by: ?memorypack.Str = null;
    var order_desc = false;
    var limit: ?usize = null;
    errdefer {
        for (group_columns.items) |group| allocator.free(group.bytes);
        group_columns.deinit(allocator);
    }
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
                    try group_columns.append(allocator, .{ .bytes = try allocator.dupe(u8, stripComma(group)) });
                    while (tokens.next()) |extra| {
                        try group_columns.append(allocator, .{ .bytes = try allocator.dupe(u8, stripComma(extra)) });
                    }
                    break;
                }
            }
        } else if (std.ascii.eqlIgnoreCase(keyword, "GROUP")) {
            const by = tokens.next() orelse return error.InvalidGroupBy;
            if (!std.ascii.eqlIgnoreCase(by, "BY")) return error.InvalidGroupBy;
            const group = tokens.next() orelse return error.InvalidGroupBy;
            try group_columns.append(allocator, .{ .bytes = try allocator.dupe(u8, stripComma(group)) });
            while (tokens.next()) |extra| try group_columns.append(allocator, .{ .bytes = try allocator.dupe(u8, stripComma(extra)) });
        } else if (std.ascii.eqlIgnoreCase(keyword, "ORDER")) {
            const by = tokens.next() orelse return error.TrailingTokens;
            if (!std.ascii.eqlIgnoreCase(by, "BY")) return error.TrailingTokens;
            const column = tokens.next() orelse return error.TrailingTokens;
            order_by = .{ .bytes = try allocator.dupe(u8, stripComma(column)) };
            if (tokens.next()) |direction| {
                if (std.ascii.eqlIgnoreCase(direction, "DESC")) order_desc = true else if (!std.ascii.eqlIgnoreCase(direction, "ASC")) return error.TrailingTokens;
            }
            if (tokens.next()) |limit_keyword| {
                if (!std.ascii.eqlIgnoreCase(limit_keyword, "LIMIT")) return error.TrailingTokens;
                limit = std.fmt.parseInt(usize, tokens.next() orelse return error.TrailingTokens, 10) catch return error.InvalidLimit;
            }
        } else return error.TrailingTokens;
    }
    return .{
        .allocator = allocator,
        .table = .{ .bytes = try allocator.dupe(u8, table) },
        .select = try select.toOwnedSlice(allocator),
        .predicates = try predicates.toOwnedSlice(allocator),
        .group_by = group_by,
        .group_by_columns = try group_columns.toOwnedSlice(allocator),
        .order_by = order_by,
        .order_desc = order_desc,
        .limit = limit,
        .threads = 1,
    };
}

fn parseJoin(allocator: std.mem.Allocator, text: []const u8) ParseError!Plan {
    var tokens = std.mem.tokenizeAny(u8, text, " \t\r\n");
    if (!std.ascii.eqlIgnoreCase(tokens.next() orelse return error.EmptyQuery, "SELECT")) return error.ExpectedSelect;
    var select: std.ArrayList(SelectItem) = .empty;
    errdefer freeSelectList(allocator, &select);
    var token = tokens.next() orelse return error.ExpectedFrom;
    while (!std.ascii.eqlIgnoreCase(stripComma(token), "FROM")) {
        try select.append(allocator, try parseSelectItem(allocator, stripComma(token)));
        token = tokens.next() orelse return error.ExpectedFrom;
    }
    const table = tokens.next() orelse return error.MissingTable;
    const join_keyword = tokens.next() orelse return error.TrailingTokens;
    var join_kind: exec.JoinKind = .inner;
    if (std.ascii.eqlIgnoreCase(join_keyword, "LEFT")) {
        join_kind = .left;
        if (!std.ascii.eqlIgnoreCase(tokens.next() orelse return error.TrailingTokens, "JOIN")) return error.TrailingTokens;
    } else if (std.ascii.eqlIgnoreCase(join_keyword, "RIGHT")) {
        join_kind = .right;
        if (!std.ascii.eqlIgnoreCase(tokens.next() orelse return error.TrailingTokens, "JOIN")) return error.TrailingTokens;
    } else if (std.ascii.eqlIgnoreCase(join_keyword, "FULL")) {
        join_kind = .full;
        if (!std.ascii.eqlIgnoreCase(tokens.next() orelse return error.TrailingTokens, "JOIN")) return error.TrailingTokens;
    } else if (!std.ascii.eqlIgnoreCase(join_keyword, "JOIN")) return error.TrailingTokens;
    const join_table = tokens.next() orelse return error.MissingTable;
    if (!std.ascii.eqlIgnoreCase(tokens.next() orelse return error.TrailingTokens, "ON")) return error.TrailingTokens;
    var left_keys: std.ArrayList(memorypack.Str) = .empty;
    var right_keys: std.ArrayList(memorypack.Str) = .empty;
    errdefer {
        for (left_keys.items) |key| allocator.free(key.bytes);
        left_keys.deinit(allocator);
        for (right_keys.items) |key| allocator.free(key.bytes);
        right_keys.deinit(allocator);
    }
    var trailing_keyword: ?[]const u8 = null;
    while (true) {
        const join_left = tokens.next() orelse return error.InvalidPredicate;
        if (!std.mem.eql(u8, tokens.next() orelse return error.InvalidOperator, "=")) return error.InvalidOperator;
        const join_right = tokens.next() orelse return error.InvalidPredicate;
        try left_keys.append(allocator, .{ .bytes = try allocator.dupe(u8, join_left) });
        try right_keys.append(allocator, .{ .bytes = try allocator.dupe(u8, join_right) });
        const separator = tokens.next() orelse break;
        if (!std.ascii.eqlIgnoreCase(separator, "AND")) {
            trailing_keyword = separator;
            break;
        }
    }
    var order_by: ?memorypack.Str = null;
    var order_desc = false;
    var limit: ?usize = null;
    const next_clause = trailing_keyword orelse tokens.next();
    if (next_clause) |keyword| {
        if (!std.ascii.eqlIgnoreCase(keyword, "ORDER")) return error.TrailingTokens;
        if (!std.ascii.eqlIgnoreCase(tokens.next() orelse return error.TrailingTokens, "BY")) return error.TrailingTokens;
        order_by = .{ .bytes = try allocator.dupe(u8, stripComma(tokens.next() orelse return error.TrailingTokens)) };
        if (tokens.next()) |direction| {
            if (std.ascii.eqlIgnoreCase(direction, "DESC")) order_desc = true else if (!std.ascii.eqlIgnoreCase(direction, "ASC")) return error.TrailingTokens;
        }
        if (tokens.next()) |limit_keyword| {
            if (!std.ascii.eqlIgnoreCase(limit_keyword, "LIMIT")) return error.TrailingTokens;
            limit = std.fmt.parseInt(usize, tokens.next() orelse return error.TrailingTokens, 10) catch return error.InvalidLimit;
        }
    }
    return .{
        .allocator = allocator,
        .table = .{ .bytes = try allocator.dupe(u8, table) },
        .select = try select.toOwnedSlice(allocator),
        .predicates = try allocator.alloc(Predicate, 0),
        .group_by = null,
        .group_by_columns = try allocator.alloc(memorypack.Str, 0),
        .order_by = order_by,
        .order_desc = order_desc,
        .limit = limit,
        .join_table = .{ .bytes = try allocator.dupe(u8, join_table) },
        .join_left = .{ .bytes = try allocator.dupe(u8, left_keys.items[0].bytes) },
        .join_right = .{ .bytes = try allocator.dupe(u8, right_keys.items[0].bytes) },
        .join_left_keys = try left_keys.toOwnedSlice(allocator),
        .join_right_keys = try right_keys.toOwnedSlice(allocator),
        .join_kind = join_kind,
        .threads = 1,
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
    var group_columns: std.ArrayList(usize) = .empty;
    errdefer group_columns.deinit(allocator);
    for (plan.group_by_columns) |group| try group_columns.append(allocator, findColumn(schema, group.bytes) orelse return error.ColumnNotFound);
    const order_by = if (plan.order_by) |order| findColumn(schema, order.bytes) orelse return error.ColumnNotFound else null;
    return .{
        .projection = try projection.toOwnedSlice(allocator),
        .predicates = try predicates.toOwnedSlice(allocator),
        .aggregates = try aggregates.toOwnedSlice(allocator),
        .group_by = group_by,
        .group_by_columns = try group_columns.toOwnedSlice(allocator),
        .order_by = order_by,
        .order_desc = plan.order_desc,
        .limit = plan.limit,
        .threads = plan.threads,
    };
}

pub fn freeQuery(allocator: std.mem.Allocator, query: *exec.Query) void {
    allocator.free(query.projection);
    for (query.predicates) |predicate| freeScalar(allocator, predicate.value);
    allocator.free(query.predicates);
    allocator.free(query.aggregates);
    allocator.free(query.group_by_columns);
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
    try std.testing.expectEqual(@as(usize, 1), query.group_by_columns[0]);
}

test "sql parser rejects malformed input" {
    try std.testing.expectError(error.ExpectedSelect, parse(std.testing.allocator, "DELETE FROM sales"));
    try std.testing.expectError(error.InvalidOperator, parse(std.testing.allocator, "SELECT amount FROM sales WHERE amount ~~ 2"));
}

test "sql parser accepts null checks and ordering" {
    var plan = try parse(std.testing.allocator, "SELECT amount FROM sales ORDER BY amount DESC LIMIT 2");
    defer plan.deinit();
    var null_plan = try parse(std.testing.allocator, "SELECT amount FROM sales WHERE amount IS NOT NULL");
    defer null_plan.deinit();
    try std.testing.expectEqual(@as(usize, 1), null_plan.predicates.len);
    try std.testing.expectEqual(false, null_plan.predicates[0].null_check.?);
    try std.testing.expectEqualStrings("amount", plan.order_by.?.bytes);
    try std.testing.expect(plan.order_desc);
    try std.testing.expectEqual(@as(usize, 2), plan.limit.?);
}

test "sql parser plans composite outer joins" {
    var plan = try parse(std.testing.allocator, "SELECT a.id, b.label FROM sales FULL JOIN lookup ON a.id = b.id AND a.team = b.team ORDER BY b.label DESC LIMIT 3");
    defer plan.deinit();
    try std.testing.expectEqual(exec.JoinKind.full, plan.join_kind);
    try std.testing.expectEqual(@as(usize, 2), plan.join_left_keys.len);
    try std.testing.expectEqualStrings("a.team", plan.join_left_keys[1].bytes);
    try std.testing.expect(plan.order_desc);
}

test "window parser accepts descending multi-column partitions" {
    var plan = try parseWindow(std.testing.allocator, "SELECT team, amount, ROW_NUMBER() OVER (PARTITION BY team, active ORDER BY amount DESC), SUM(amount) OVER (PARTITION BY team, active ORDER BY amount DESC) FROM sales");
    defer plan.deinit();
    try std.testing.expectEqual(@as(usize, 2), plan.partition_by.len);
    try std.testing.expect(plan.order_desc);
    try std.testing.expectEqual(exec.WindowKind.row_number, plan.functions[0].kind);
    try std.testing.expectEqual(exec.WindowKind.running_sum, plan.functions[1].kind);
}
