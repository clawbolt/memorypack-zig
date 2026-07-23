const std = @import("std");
const builtin = @import("builtin");

pub const Error = error{ EndOfStream, InvalidData, OutOfMemory };
const Allocator = std.mem.Allocator;

pub const Str = struct {
    bytes: []const u8,
};

pub const Guid = struct {
    pub const memorypack_builtin = .guid;
    bytes: [16]u8,
};

pub const DateTime = struct {
    pub const memorypack_builtin = .date_time;
    date_data: i64,
};

pub const DateTimeOffset = struct {
    pub const memorypack_builtin = .date_time_offset;
    offset_minutes: i64,
    ticks: i64,
};

pub const TimeSpan = struct {
    pub const memorypack_builtin = .time_span;
    ticks: i64,
};

pub const Decimal = struct {
    pub const memorypack_builtin = .decimal;
    flags: i32,
    hi: i32,
    lo: i32,
    mid: i32,
};

pub const Version = struct {
    pub const memorypack_builtin = .version;
    major: i32,
    minor: i32,
    build: i32,
    revision: i32,
};

pub const Uri = struct {
    pub const memorypack_builtin = .uri;
    value: Str,
};

pub const DateOnly = struct {
    pub const memorypack_builtin = .date_only;
    day_number: i32,
};

pub const TimeOnly = struct {
    pub const memorypack_builtin = .time_only;
    ticks: i64,
};

pub const BitArray = struct {
    pub const memorypack_builtin = .bit_array;
    bit_length: i32,
    bytes: []const u8,
};

pub const Complex = struct {
    pub const memorypack_builtin = .complex;
    real: f64,
    imaginary: f64,
};

pub const StringBuilder = struct {
    pub const memorypack_builtin = .string_builder;
    value: Str,
};

const BuiltinKind = enum { guid, date_time, date_time_offset, time_span, decimal, version, uri, date_only, time_only, bit_array, complex, string_builder };

pub fn KeyValue(comptime K: type, comptime V: type) type {
    return struct {
        pub const memorypack_tuple = true;
        key: K,
        value: V,
    };
}

pub fn Tuple3(comptime A: type, comptime B: type, comptime C: type) type {
    return struct {
        pub const memorypack_tuple = true;
        item0: A,
        item1: B,
        item2: C,
    };
}

pub fn Tuple4(comptime A: type, comptime B: type, comptime C: type, comptime D: type) type {
    return struct {
        pub const memorypack_tuple = true;
        item0: A,
        item1: B,
        item2: C,
        item3: D,
    };
}

pub fn Dictionary(comptime K: type, comptime V: type) type {
    return []const KeyValue(K, V);
}

pub fn Array(comptime rank: usize, comptime T: type) type {
    return struct {
        pub const memorypack_multidimensional_rank = rank;
        dimensions: [rank]i32,
        values: []const T,
    };
}

pub fn Array2(comptime T: type) type {
    return Array(2, T);
}

fn isStr(comptime T: type) bool {
    return T == Str;
}

fn builtinKind(comptime T: type) ?BuiltinKind {
    if (@typeInfo(T) != .@"struct" or !@hasDecl(T, "memorypack_builtin")) return null;
    return @field(T, "memorypack_builtin");
}

fn isBuiltin(comptime T: type) bool {
    return builtinKind(T) != null;
}

fn isTuple(comptime T: type) bool {
    return @typeInfo(T) == .@"struct" and @hasDecl(T, "memorypack_tuple");
}

fn isUnion(comptime T: type) bool {
    return @typeInfo(T) == .@"union";
}

fn isVersionTolerant(comptime T: type) bool {
    return @typeInfo(T) == .@"struct" and @hasDecl(T, "memorypack_version_tolerant");
}

fn isCircularReference(comptime T: type) bool {
    return @typeInfo(T) == .@"struct" and @hasDecl(T, "memorypack_circular_reference");
}

fn isExplicit(comptime T: type) bool {
    return @typeInfo(T) == .@"struct" and @hasDecl(T, "memorypack_explicit");
}

fn isMultiDimensional(comptime T: type) bool {
    return @typeInfo(T) == .@"struct" and @hasDecl(T, "memorypack_multidimensional_rank");
}

fn isIgnored(comptime T: type, comptime field_name: []const u8) bool {
    return @hasDecl(T, "memorypack_ignore_" ++ field_name);
}

fn isIncluded(comptime T: type, comptime field_name: []const u8) bool {
    if (!@hasDecl(T, "memorypack_include_only")) return true;
    return @hasDecl(T, "memorypack_include_" ++ field_name);
}

fn isSerializedField(comptime T: type, comptime field_name: []const u8) bool {
    return !isIgnored(T, field_name) and isIncluded(T, field_name);
}

fn defaultValue(comptime T: type) T {
    return switch (@typeInfo(T)) {
        .@"enum" => |e| @enumFromInt(@intFromEnum(@field(T, e.fields[0].name))),
        else => std.mem.zeroes(T),
    };
}

fn serializedFieldCount(comptime T: type) usize {
    comptime var count: usize = 0;
    inline for (std.meta.fields(T)) |f| {
        if (comptime isSerializedField(T, f.name)) count += 1;
    }
    return comptime count;
}

fn explicitOrder(comptime T: type, comptime field_name: []const u8) usize {
    return comptime @field(T, "memorypack_order_" ++ field_name);
}

fn explicitCount(comptime T: type) usize {
    return comptime @field(T, "memorypack_explicit_count");
}

fn isFixed(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .bool, .int, .float, .@"enum" => true,
        .array => |a| isFixed(a.child),
        .@"struct" => |s| blk: {
            if (s.layout != .@"extern" or isStr(T) or isTuple(T) or isBuiltin(T) or isMultiDimensional(T)) break :blk false;
            inline for (std.meta.fields(T)) |f| {
                if (!isFixed(f.type)) break :blk false;
            }
            break :blk true;
        },
        else => false,
    };
}

fn isObject(comptime T: type) bool {
    return @typeInfo(T) == .@"struct" and !isStr(T) and !isTuple(T) and !isBuiltin(T) and !isMultiDimensional(T) and !isFixed(T);
}

fn callHook(comptime T: type, comptime name: []const u8, value: *T) void {
    if (comptime @hasDecl(T, name)) @field(T, name)(value);
}

fn take(reader: *Reader, n: usize) Error![]const u8 {
    if (n > reader.buf.len -| reader.pos) return error.EndOfStream;
    const result = reader.buf[reader.pos..][0..n];
    reader.pos += n;
    return result;
}

fn append(writer: *Writer, bytes: []const u8) Error!void {
    writer.list.appendSlice(writer.gpa, bytes) catch return error.OutOfMemory;
}

fn writeI32(writer: *Writer, value: i32) Error!void {
    var bytes: [4]u8 = undefined;
    std.mem.writeInt(i32, &bytes, value, .little);
    try append(writer, &bytes);
}

fn readI32(reader: *Reader) Error!i32 {
    return std.mem.readInt(i32, @ptrCast((try take(reader, 4)).ptr), .little);
}

fn writeTypeCode(writer: *Writer, value: i64) Error!void {
    if (value >= 0 and value <= 127) return append(writer, &[_]u8{@intCast(value)});
    if (value < 0 and value >= -120) return append(writer, &[_]u8{@bitCast(@as(i8, @intCast(value)))});
    if (value >= 0 and value <= std.math.maxInt(u8)) {
        try append(writer, &[_]u8{@bitCast(@as(i8, -121))});
        return append(writer, &[_]u8{@intCast(value)});
    }
    if (value < 0 and value >= std.math.minInt(i8)) {
        try append(writer, &[_]u8{@bitCast(@as(i8, -122))});
        return append(writer, &[_]u8{@bitCast(@as(i8, @intCast(value)))});
    }
    if (value >= 0 and value <= std.math.maxInt(u16)) {
        try append(writer, &[_]u8{@bitCast(@as(i8, -123))});
        var bytes: [2]u8 = undefined;
        std.mem.writeInt(u16, &bytes, @intCast(value), .little);
        return append(writer, &bytes);
    }
    if (value < 0 and value >= std.math.minInt(i16)) {
        try append(writer, &[_]u8{@bitCast(@as(i8, -124))});
        var bytes: [2]u8 = undefined;
        std.mem.writeInt(i16, &bytes, @intCast(value), .little);
        return append(writer, &bytes);
    }
    if (value >= 0 and value <= std.math.maxInt(u32)) {
        try append(writer, &[_]u8{@bitCast(@as(i8, -125))});
        var bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &bytes, @intCast(value), .little);
        return append(writer, &bytes);
    }
    if (value < 0 and value >= std.math.minInt(i32)) {
        try append(writer, &[_]u8{@bitCast(@as(i8, -126))});
        var bytes: [4]u8 = undefined;
        std.mem.writeInt(i32, &bytes, @intCast(value), .little);
        return append(writer, &bytes);
    }
    if (value >= 0) {
        try append(writer, &[_]u8{@bitCast(@as(i8, -127))});
        var bytes: [8]u8 = undefined;
        std.mem.writeInt(u64, &bytes, @intCast(value), .little);
        return append(writer, &bytes);
    }
    try append(writer, &[_]u8{@bitCast(@as(i8, -128))});
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(i64, &bytes, value, .little);
    return append(writer, &bytes);
}

fn readTypeCode(reader: *Reader) Error!i64 {
    const code: i8 = @bitCast((try take(reader, 1))[0]);
    if (code >= -120 and code <= 127) return code;
    return switch (code) {
        -121 => std.mem.readInt(u8, @ptrCast((try take(reader, 1)).ptr), .little),
        -122 => std.mem.readInt(i8, @ptrCast((try take(reader, 1)).ptr), .little),
        -123 => std.mem.readInt(u16, @ptrCast((try take(reader, 2)).ptr), .little),
        -124 => std.mem.readInt(i16, @ptrCast((try take(reader, 2)).ptr), .little),
        -125 => @intCast(std.mem.readInt(u32, @ptrCast((try take(reader, 4)).ptr), .little)),
        -126 => std.mem.readInt(i32, @ptrCast((try take(reader, 4)).ptr), .little),
        -127 => @intCast(std.mem.readInt(u64, @ptrCast((try take(reader, 8)).ptr), .little)),
        -128 => std.mem.readInt(i64, @ptrCast((try take(reader, 8)).ptr), .little),
        else => error.InvalidData,
    };
}

fn writePrimitive(writer: *Writer, comptime T: type, value: T) Error!void {
    switch (@typeInfo(T)) {
        .bool => try append(writer, &[_]u8{@intFromBool(value)}),
        .int => {
            var bytes: [@sizeOf(T)]u8 = undefined;
            std.mem.writeInt(T, &bytes, value, .little);
            try append(writer, &bytes);
        },
        .float => {
            const IntT = std.meta.Int(.unsigned, @bitSizeOf(T));
            var bytes: [@sizeOf(T)]u8 = undefined;
            std.mem.writeInt(IntT, &bytes, @bitCast(value), .little);
            try append(writer, &bytes);
        },
        .@"enum" => try writePrimitive(writer, @typeInfo(T).@"enum".tag_type, @intFromEnum(value)),
        else => @compileError("not a primitive: " ++ @typeName(T)),
    }
}

fn readPrimitive(reader: *Reader, comptime T: type) Error!T {
    switch (@typeInfo(T)) {
        .bool => {
            const b = (try take(reader, 1))[0];
            if (b > 1) return error.InvalidData;
            return b != 0;
        },
        .int => return std.mem.readInt(T, @ptrCast((try take(reader, @sizeOf(T))).ptr), .little),
        .float => {
            const IntT = std.meta.Int(.unsigned, @bitSizeOf(T));
            return @bitCast(std.mem.readInt(IntT, @ptrCast((try take(reader, @sizeOf(T))).ptr), .little));
        },
        .@"enum" => |e| return @enumFromInt(try readPrimitive(reader, e.tag_type)),
        else => @compileError("not a primitive: " ++ @typeName(T)),
    }
}

fn writeBuiltin(writer: *Writer, comptime T: type, value: T) Error!void {
    switch (comptime builtinKind(T).?) {
        .guid => {
            const bytes = value.bytes;
            try append(writer, &[_]u8{
                bytes[3],  bytes[2],  bytes[1],  bytes[0],
                bytes[5],  bytes[4],  bytes[7],  bytes[6],
                bytes[8],  bytes[9],  bytes[10], bytes[11],
                bytes[12], bytes[13], bytes[14], bytes[15],
            });
        },
        .date_time => try writePrimitive(writer, i64, value.date_data),
        .date_time_offset => {
            try writePrimitive(writer, i64, value.offset_minutes);
            try writePrimitive(writer, i64, value.ticks);
        },
        .time_span => try writePrimitive(writer, i64, value.ticks),
        .decimal => {
            try writePrimitive(writer, i32, value.flags);
            try writePrimitive(writer, i32, value.hi);
            try writePrimitive(writer, i32, value.lo);
            try writePrimitive(writer, i32, value.mid);
        },
        .version => {
            try append(writer, &[_]u8{4});
            try writePrimitive(writer, i32, value.major);
            try writePrimitive(writer, i32, value.minor);
            try writePrimitive(writer, i32, value.build);
            try writePrimitive(writer, i32, value.revision);
        },
        .uri => try writeString(writer, value.value.bytes),
        .date_only => try writePrimitive(writer, i32, value.day_number),
        .time_only => try writePrimitive(writer, i64, value.ticks),
        .bit_array => {
            if (value.bit_length < 0 or (@as(usize, @intCast(value.bit_length)) + 7) / 8 != value.bytes.len)
                return error.InvalidData;
            try append(writer, &[_]u8{2});
            try writePrimitive(writer, i32, value.bit_length);
            const word_count = (@as(usize, @intCast(value.bit_length)) + 31) / 32;
            try writeI32(writer, @intCast(word_count));
            for (0..word_count) |word| {
                var word_value: u32 = 0;
                const start = word * 4;
                for (0..4) |offset| {
                    if (start + offset < value.bytes.len)
                        word_value |= @as(u32, value.bytes[start + offset]) << @intCast(offset * 8);
                }
                try writePrimitive(writer, u32, word_value);
            }
        },
        .complex => {
            try writePrimitive(writer, f64, value.real);
            try writePrimitive(writer, f64, value.imaginary);
        },
        .string_builder => {
            if (value.value.bytes.len > std.math.maxInt(i32) / 2) return error.InvalidData;
            try writePrimitive(writer, i32, @intCast(value.value.bytes.len));
            for (value.value.bytes) |byte| {
                try append(writer, &[_]u8{ byte, 0 });
            }
        },
    }
}

fn readBuiltin(reader: *Reader, comptime T: type, gpa: Allocator) Error!T {
    switch (comptime builtinKind(T).?) {
        .guid => {
            const wire = try take(reader, 16);
            var bytes: [16]u8 = undefined;
            bytes[0] = wire[3];
            bytes[1] = wire[2];
            bytes[2] = wire[1];
            bytes[3] = wire[0];
            bytes[4] = wire[5];
            bytes[5] = wire[4];
            bytes[6] = wire[7];
            bytes[7] = wire[6];
            @memcpy(bytes[8..], wire[8..]);
            return .{ .bytes = bytes };
        },
        .date_time => return .{ .date_data = try readPrimitive(reader, i64) },
        .date_time_offset => return .{
            .offset_minutes = try readPrimitive(reader, i64),
            .ticks = try readPrimitive(reader, i64),
        },
        .time_span => return .{ .ticks = try readPrimitive(reader, i64) },
        .decimal => return .{
            .flags = try readPrimitive(reader, i32),
            .hi = try readPrimitive(reader, i32),
            .lo = try readPrimitive(reader, i32),
            .mid = try readPrimitive(reader, i32),
        },
        .version => {
            if ((try take(reader, 1))[0] != 4) return error.InvalidData;
            return .{
                .major = try readPrimitive(reader, i32),
                .minor = try readPrimitive(reader, i32),
                .build = try readPrimitive(reader, i32),
                .revision = try readPrimitive(reader, i32),
            };
        },
        .uri => {
            const bytes = try readString(reader, gpa) orelse return error.InvalidData;
            return .{ .value = .{ .bytes = bytes } };
        },
        .date_only => return .{ .day_number = try readPrimitive(reader, i32) },
        .time_only => return .{ .ticks = try readPrimitive(reader, i64) },
        .bit_array => {
            if ((try take(reader, 1))[0] != 2) return error.InvalidData;
            const bit_length = try readPrimitive(reader, i32);
            if (bit_length < 0) return error.InvalidData;
            const byte_length = (@as(usize, @intCast(bit_length)) + 7) / 8;
            const word_count = (@as(usize, @intCast(bit_length)) + 31) / 32;
            const encoded_length = try readI32(reader);
            if (encoded_length < 0 or @as(usize, @intCast(encoded_length)) != word_count) return error.InvalidData;
            const bytes = gpa.alloc(u8, byte_length) catch return error.OutOfMemory;
            errdefer gpa.free(bytes);
            for (0..word_count) |word| {
                const word_value = try readPrimitive(reader, u32);
                const start = word * 4;
                for (0..4) |offset| {
                    if (start + offset < bytes.len)
                        bytes[start + offset] = @intCast((word_value >> @intCast(offset * 8)) & 0xff);
                }
            }
            return .{ .bit_length = bit_length, .bytes = bytes };
        },
        .complex => return .{
            .real = try readPrimitive(reader, f64),
            .imaginary = try readPrimitive(reader, f64),
        },
        .string_builder => {
            const length = try readPrimitive(reader, i32);
            if (length < 0) return error.InvalidData;
            const bytes = gpa.alloc(u8, @intCast(length)) catch return error.OutOfMemory;
            errdefer gpa.free(bytes);
            for (bytes) |*byte| {
                const utf16 = try take(reader, 2);
                if (utf16[1] != 0) return error.InvalidData;
                byte.* = utf16[0];
            }
            return .{ .value = .{ .bytes = bytes } };
        },
    }
}

fn utf16Length(bytes: []const u8) Error!i32 {
    var i: usize = 0;
    var count: usize = 0;
    while (i < bytes.len) {
        const cp_len = std.unicode.utf8ByteSequenceLength(bytes[i]) catch return error.InvalidData;
        if (i + cp_len > bytes.len) return error.InvalidData;
        const cp = std.unicode.utf8Decode(bytes[i..][0..cp_len]) catch return error.InvalidData;
        count += if (cp > 0xffff) 2 else 1;
        i += cp_len;
    }
    if (count > std.math.maxInt(i32)) return error.InvalidData;
    return @intCast(count);
}

fn writeString(writer: *Writer, bytes: ?[]const u8) Error!void {
    if (bytes == null) {
        try writeI32(writer, -1);
        return;
    }
    if (bytes.?.len == 0) {
        try writeI32(writer, 0);
        return;
    }
    const utf16_len = try utf16Length(bytes.?);
    const encoded_count: i32 = @bitCast(~@as(u32, @intCast(bytes.?.len)));
    try writeI32(writer, encoded_count);
    try writeI32(writer, utf16_len);
    try append(writer, bytes.?);
}

fn readString(reader: *Reader, gpa: Allocator) Error!?[]u8 {
    const first = try readI32(reader);
    if (first == -1) return null;
    if (first == 0) return gpa.alloc(u8, 0) catch error.OutOfMemory;
    if (first <= -2) {
        const byte_count: usize = @intCast(~@as(u32, @bitCast(first)));
        _ = try readI32(reader);
        const bytes = try take(reader, byte_count);
        const result = gpa.alloc(u8, byte_count) catch return error.OutOfMemory;
        @memcpy(result, bytes);
        return result;
    }
    const utf16_count: usize = @intCast(first);
    if (utf16_count > std.math.maxInt(usize) / 2) return error.InvalidData;
    const raw = try take(reader, utf16_count * 2);
    const units = gpa.alloc(u16, utf16_count) catch return error.OutOfMemory;
    defer gpa.free(units);
    for (units, 0..) |*unit, i| unit.* = std.mem.readInt(u16, @ptrCast(raw[i * 2 ..][0..2].ptr), .little);
    return std.unicode.utf16LeToUtf8Alloc(gpa, units) catch error.InvalidData;
}

fn writeCollection(writer: *Writer, comptime Elem: type, values: ?[]const Elem) Error!void {
    if (values == null) {
        try writeI32(writer, -1);
        return;
    }
    if (values.?.len > std.math.maxInt(i32)) return error.InvalidData;
    try writeI32(writer, @intCast(values.?.len));
    if (Elem == u8) {
        try append(writer, std.mem.sliceAsBytes(values.?));
    } else {
        for (values.?) |item| try writeValueImpl(writer, Elem, item);
    }
}

fn readCollection(reader: *Reader, comptime Elem: type, gpa: Allocator) Error!?[]Elem {
    const length = try readI32(reader);
    if (length == -1) return null;
    if (length < -1) return error.InvalidData;
    const result = gpa.alloc(Elem, @intCast(length)) catch return error.OutOfMemory;
    errdefer gpa.free(result);
    if (Elem == u8) {
        const bytes = try take(reader, result.len);
        @memcpy(result, bytes);
    } else {
        for (result) |*item| item.* = try readValueImpl(reader, Elem, gpa);
    }
    return result;
}

fn writeMultiDimensional(writer: *Writer, comptime T: type, value: T) Error!void {
    const Elem = @typeInfo(@TypeOf(value.values)).pointer.child;
    const rank = comptime @field(T, "memorypack_multidimensional_rank");
    var expected: usize = 1;
    inline for (0..rank) |i| {
        if (value.dimensions[i] < 0) return error.InvalidData;
        expected = std.math.mul(usize, expected, @intCast(value.dimensions[i])) catch return error.InvalidData;
    }
    if (value.values.len != expected or expected > std.math.maxInt(i32)) return error.InvalidData;
    try append(writer, &[_]u8{@intCast(rank + 1)});
    inline for (0..rank) |i| try writePrimitive(writer, i32, value.dimensions[i]);
    try writeI32(writer, @intCast(value.values.len));
    if (Elem == u8) {
        try append(writer, std.mem.sliceAsBytes(value.values));
    } else {
        for (value.values) |item| try writeValueImpl(writer, Elem, item);
    }
}

fn readMultiDimensional(reader: *Reader, comptime T: type, gpa: Allocator) Error!T {
    const Elem = @typeInfo(@TypeOf(@as(T, undefined).values)).pointer.child;
    const rank = comptime @field(T, "memorypack_multidimensional_rank");
    if ((try take(reader, 1))[0] != rank + 1) return error.InvalidData;
    var dimensions: [rank]i32 = undefined;
    var expected: usize = 1;
    inline for (0..rank) |i| {
        dimensions[i] = try readPrimitive(reader, i32);
        if (dimensions[i] < 0) return error.InvalidData;
        expected = std.math.mul(usize, expected, @intCast(dimensions[i])) catch return error.InvalidData;
    }
    const length = try readI32(reader);
    if (length < 0) return error.InvalidData;
    if (@as(usize, @intCast(length)) != expected) return error.InvalidData;
    const values = gpa.alloc(Elem, expected) catch return error.OutOfMemory;
    errdefer gpa.free(values);
    if (Elem == u8) {
        const bytes = try take(reader, expected);
        @memcpy(values, bytes);
    } else {
        for (values) |*item| item.* = try readValueImpl(reader, Elem, gpa);
    }
    return .{ .dimensions = dimensions, .values = values };
}

fn writeExplicit(writer: *Writer, comptime T: type, value: T) Error!void {
    const count = comptime explicitCount(T);
    try append(writer, &[_]u8{@intCast(count)});
    inline for (0..comptime count) |order| {
        var found = false;
        inline for (std.meta.fields(T)) |f| {
            if (comptime explicitOrder(T, f.name) == order) {
                found = true;
                try writeValueImpl(writer, f.type, @field(value, f.name));
            }
        }
        if (!found) try append(writer, &[_]u8{0});
    }
}

fn readExplicit(reader: *Reader, comptime T: type, gpa: Allocator) Error!T {
    const header = (try take(reader, 1))[0];
    if (header == 255 or header != explicitCount(T)) return error.InvalidData;
    var result: T = std.mem.zeroes(T);
    inline for (0..comptime explicitCount(T)) |order| {
        var found = false;
        inline for (std.meta.fields(T)) |f| {
            if (comptime explicitOrder(T, f.name) == order) {
                found = true;
                @field(result, f.name) = try readValueImpl(reader, f.type, gpa);
            }
        }
        if (!found) _ = try take(reader, 1);
    }
    return result;
}

fn writeVersionTolerant(writer: *Writer, comptime T: type, value: T) Error!void {
    const fields = std.meta.fields(T);
    if (fields.len > 249) @compileError("MemoryPack version-tolerant member count exceeds 249");
    var encoded: [249][]u8 = undefined;
    var lengths: [249]usize = undefined;
    var count: usize = 0;
    defer while (count > 0) {
        count -= 1;
        writer.gpa.free(encoded[count]);
    };
    inline for (fields, 0..) |f, i| {
        var member_writer = Writer.initWithRefs(writer.gpa, writer.refMap(), writer.nextRefId());
        errdefer member_writer.deinit();
        try writeValueImpl(&member_writer, f.type, @field(value, f.name));
        encoded[i] = try member_writer.toOwnedSlice();
        lengths[i] = encoded[i].len;
        count += 1;
    }
    try append(writer, &[_]u8{@intCast(fields.len)});
    for (lengths[0..fields.len]) |length| try writeTypeCode(writer, @intCast(length));
    for (encoded[0..fields.len]) |bytes| try append(writer, bytes);
}

fn readVersionTolerant(reader: *Reader, comptime T: type, gpa: Allocator) Error!T {
    const header = (try take(reader, 1))[0];
    if (header == 255) return error.InvalidData;
    if (header == 250) return error.InvalidData;
    const count: usize = header;
    var lengths: [249]usize = undefined;
    for (lengths[0..count]) |*length| {
        const value = try readTypeCode(reader);
        if (value < 0) return error.InvalidData;
        length.* = @intCast(value);
    }
    var result: T = std.mem.zeroes(T);
    var index: usize = 0;
    inline for (std.meta.fields(T)) |f| {
        if (index < count) {
            const start = reader.pos;
            @field(result, f.name) = try readValueImpl(reader, f.type, gpa);
            if (reader.pos - start > lengths[index]) return error.InvalidData;
            reader.pos = start + lengths[index];
        }
        index += 1;
    }
    while (index < count) : (index += 1) {
        _ = try take(reader, lengths[index]);
    }
    return result;
}

fn writeCircular(writer: *Writer, comptime T: type, value: *T) Error!void {
    const address = @intFromPtr(value);
    if (writer.refMap().get(address)) |ref_id| {
        try append(writer, &[_]u8{250});
        return writeTypeCode(writer, @intCast(ref_id));
    }
    const ref_id = writer.nextRefId().*;
    writer.nextRefId().* += 1;
    try writer.refMap().put(address, ref_id);

    const fields = std.meta.fields(T);
    if (fields.len > 249) @compileError("MemoryPack circular-reference member count exceeds 249");
    var encoded: [249][]u8 = undefined;
    var lengths: [249]usize = undefined;
    var count: usize = 0;
    defer while (count > 0) {
        count -= 1;
        writer.gpa.free(encoded[count]);
    };
    inline for (fields, 0..) |f, i| {
        var member_writer = Writer.initWithRefs(writer.gpa, writer.refMap(), writer.nextRefId());
        errdefer member_writer.deinit();
        try writeValueImpl(&member_writer, f.type, @field(value.*, f.name));
        encoded[i] = try member_writer.toOwnedSlice();
        lengths[i] = encoded[i].len;
        count += 1;
    }
    try append(writer, &[_]u8{@intCast(fields.len)});
    for (lengths[0..fields.len]) |length| try writeTypeCode(writer, @intCast(length));
    try writeTypeCode(writer, @intCast(ref_id));
    for (encoded[0..fields.len]) |bytes| try append(writer, bytes);
}

fn writeTuple(writer: *Writer, comptime T: type, value: T) Error!void {
    inline for (std.meta.fields(T)) |f| {
        try writeValueImpl(writer, f.type, @field(value, f.name));
    }
}

fn writeUnion(writer: *Writer, comptime T: type, value: T) Error!void {
    const tag = std.meta.activeTag(value);
    const Tag = @typeInfo(T).@"union".tag_type.?;
    const tag_value: u16 = @intCast(@intFromEnum(tag));
    if (tag_value < 250) {
        try append(writer, &[_]u8{@intCast(tag_value)});
    } else {
        try append(writer, &[_]u8{250});
        var tag_bytes: [2]u8 = undefined;
        std.mem.writeInt(u16, &tag_bytes, tag_value, .little);
        try append(writer, &tag_bytes);
    }
    inline for (std.meta.fields(T)) |f| {
        if (@intFromEnum(tag) == @intFromEnum(@field(Tag, f.name))) {
            try writeValueImpl(writer, f.type, @field(value, f.name));
        }
    }
}

fn writeValueImpl(writer: *Writer, comptime T: type, value: T) Error!void {
    if (comptime isStr(T)) return writeString(writer, value.bytes);
    if (comptime isBuiltin(T)) return writeBuiltin(writer, T, value);
    if (comptime isMultiDimensional(T)) return writeMultiDimensional(writer, T, value);
    if (comptime isTuple(T)) return writeTuple(writer, T, value);
    if (comptime isVersionTolerant(T)) return writeVersionTolerant(writer, T, value);
    if (comptime isExplicit(T)) return writeExplicit(writer, T, value);
    switch (@typeInfo(T)) {
        .bool, .int, .float, .@"enum" => try writePrimitive(writer, T, value),
        .optional => |o| {
            if (comptime isStr(o.child)) return writeString(writer, if (value) |v| v.bytes else null);
            if (comptime (@typeInfo(o.child) == .pointer and @typeInfo(o.child).pointer.size == .slice)) {
                return writeCollection(writer, @typeInfo(o.child).pointer.child, if (value) |v| v else null);
            }
            if (comptime (@typeInfo(o.child) == .pointer and @typeInfo(o.child).pointer.size == .one and
                @typeInfo(@typeInfo(o.child).pointer.child) == .@"struct" and
                isCircularReference(@typeInfo(o.child).pointer.child)))
            {
                if (value == null) return append(writer, &[_]u8{255});
                return writeCircular(writer, @typeInfo(o.child).pointer.child, value.?);
            }
            if (comptime isObject(o.child)) {
                if (value == null) return append(writer, &[_]u8{255});
                return writeValueImpl(writer, o.child, value.?);
            }
            if (comptime isUnion(o.child)) {
                if (value == null) return append(writer, &[_]u8{255});
                return writeUnion(writer, o.child, value.?);
            }
            try writeI32(writer, if (value == null) 0 else 1);
            if (value) |v| {
                try writeValueImpl(writer, o.child, v);
            } else {
                try writeValueImpl(writer, o.child, std.mem.zeroes(o.child));
            }
        },
        .@"struct" => |s| {
            if (comptime isVersionTolerant(T)) return writeVersionTolerant(writer, T, value);
            if (s.layout == .@"extern" and isFixed(T)) {
                if (comptime builtin.cpu.arch.endian() != .little) @compileError("MemoryPack requires a little-endian host");
                try append(writer, std.mem.asBytes(&value));
            } else {
                const field_count = comptime serializedFieldCount(T);
                if (field_count > 249) @compileError("MemoryPack object member count exceeds 249");
                var mutable = value;
                callHook(T, "memorypackOnSerializing", &mutable);
                try append(writer, &[_]u8{@intCast(field_count)});
                inline for (std.meta.fields(T)) |f| {
                    if (comptime isSerializedField(T, f.name))
                        try writeValueImpl(writer, f.type, @field(mutable, f.name));
                }
                callHook(T, "memorypackOnSerialized", &mutable);
            }
        },
        .@"union" => try writeUnion(writer, T, value),
        .pointer => |p| switch (p.size) {
            .slice => try writeCollection(writer, p.child, value),
            .one => switch (@typeInfo(p.child)) {
                .@"struct" => if (comptime isCircularReference(p.child))
                    try writeCircular(writer, p.child, value)
                else
                    @compileError("MemoryPack supports only circular-reference object pointers"),
                .array => try writeCollection(writer, @typeInfo(p.child).array.child, value.*[0..]),
                else => @compileError("MemoryPack supports only slices and pointers to arrays"),
            },
            else => @compileError("MemoryPack supports only slices and single-item pointers"),
        },
        .array => |a| try writeCollection(writer, a.child, value[0..]),
        else => @compileError("unsupported MemoryPack type: " ++ @typeName(T)),
    }
}

fn readValueImpl(reader: *Reader, comptime T: type, gpa: Allocator) Error!T {
    if (comptime isStr(T)) {
        const bytes = try readString(reader, gpa) orelse return error.InvalidData;
        return .{ .bytes = bytes };
    }
    if (comptime isBuiltin(T)) return readBuiltin(reader, T, gpa);
    if (comptime isMultiDimensional(T)) return readMultiDimensional(reader, T, gpa);
    if (comptime isTuple(T)) {
        var result: T = undefined;
        inline for (std.meta.fields(T)) |f| {
            @field(result, f.name) = try readValueImpl(reader, f.type, gpa);
        }
        return result;
    }
    if (comptime isVersionTolerant(T)) return readVersionTolerant(reader, T, gpa);
    if (comptime isExplicit(T)) return readExplicit(reader, T, gpa);
    switch (@typeInfo(T)) {
        .bool, .int, .float, .@"enum" => return readPrimitive(reader, T),
        .optional => |o| {
            if (comptime isStr(o.child)) {
                const bytes = try readString(reader, gpa);
                return if (bytes) |b| .{ .bytes = b } else null;
            }
            if (comptime (@typeInfo(o.child) == .pointer and @typeInfo(o.child).pointer.size == .slice)) {
                const values = try readCollection(reader, @typeInfo(o.child).pointer.child, gpa);
                return values;
            }
            if (comptime (@typeInfo(o.child) == .pointer and @typeInfo(o.child).pointer.size == .one and
                @typeInfo(@typeInfo(o.child).pointer.child) == .@"struct" and
                isCircularReference(@typeInfo(o.child).pointer.child)))
            {
                const header = (try take(reader, 1))[0];
                if (header == 255) return null;
                reader.pos -= 1;
                return try readCircular(reader, @typeInfo(o.child).pointer.child, gpa);
            }
            if (comptime isObject(o.child)) {
                const header = (try take(reader, 1))[0];
                if (header == 255) return null;
                const field_count = comptime serializedFieldCount(o.child);
                if (header != field_count) return error.InvalidData;
                var result: o.child = undefined;
                inline for (std.meta.fields(o.child)) |f| {
                    if (comptime isSerializedField(o.child, f.name)) {
                        @field(result, f.name) = try readValueImpl(reader, f.type, gpa);
                    } else {
                        @field(result, f.name) = defaultValue(f.type);
                    }
                }
                return result;
            }
            if (comptime isUnion(o.child)) {
                const tag_byte = (try take(reader, 1))[0];
                if (tag_byte == 255) return null;
                const raw_tag: u16 = if (tag_byte == 250)
                    std.mem.readInt(u16, @ptrCast((try take(reader, 2)).ptr), .little)
                else
                    tag_byte;
                return try readUnion(reader, o.child, raw_tag, gpa);
            }
            const present = try readI32(reader);
            if (present == 0) {
                var discarded = try readValueImpl(reader, o.child, gpa);
                deinit(o.child, gpa, &discarded);
                return null;
            }
            if (present != 1) return error.InvalidData;
            return try readValueImpl(reader, o.child, gpa);
        },
        .@"struct" => |s| {
            var result: T = undefined;
            if (comptime isVersionTolerant(T)) return readVersionTolerant(reader, T, gpa);
            if (s.layout == .@"extern" and isFixed(T)) {
                const bytes = try take(reader, @sizeOf(T));
                @memcpy(std.mem.asBytes(&result), bytes);
            } else {
                const header = (try take(reader, 1))[0];
                const field_count = comptime serializedFieldCount(T);
                if (header == 255 or header != field_count) return error.InvalidData;
                callHook(T, "memorypackOnDeserializing", &result);
                inline for (std.meta.fields(T)) |f| {
                    if (comptime isSerializedField(T, f.name)) {
                        @field(result, f.name) = try readValueImpl(reader, f.type, gpa);
                    } else {
                        @field(result, f.name) = defaultValue(f.type);
                    }
                }
                callHook(T, "memorypackOnDeserialized", &result);
            }
            return result;
        },
        .@"union" => {
            const tag_byte = (try take(reader, 1))[0];
            if (tag_byte == 255) return error.InvalidData;
            const raw_tag: u16 = if (tag_byte == 250)
                std.mem.readInt(u16, @ptrCast((try take(reader, 2)).ptr), .little)
            else
                tag_byte;
            return readUnion(reader, T, raw_tag, gpa);
        },
        .pointer => |p| switch (p.size) {
            .slice => {
                const values = try readCollection(reader, p.child, gpa) orelse return error.InvalidData;
                return values;
            },
            .one => switch (@typeInfo(p.child)) {
                .@"struct" => if (comptime isCircularReference(p.child))
                    return readCircular(reader, p.child, gpa)
                else
                    @compileError("MemoryPack supports only circular-reference object pointers"),
                else => @compileError("MemoryPack supports only slices and circular-reference pointers"),
            },
            else => @compileError("MemoryPack supports only slices and single-item pointers"),
        },
        .array => |a| {
            const values = try readCollection(reader, a.child, gpa) orelse return error.InvalidData;
            if (values.len != a.len) return error.InvalidData;
            var result: T = undefined;
            @memcpy(&result, values);
            gpa.free(values);
            return result;
        },
        else => @compileError("unsupported MemoryPack type: " ++ @typeName(T)),
    }
}

fn readUnion(reader: *Reader, comptime T: type, raw_tag: u16, gpa: Allocator) Error!T {
    const union_info = @typeInfo(T).@"union";
    const Tag = union_info.tag_type orelse return error.InvalidData;
    inline for (std.meta.fields(T)) |f| {
        if (raw_tag == @intFromEnum(@field(Tag, f.name))) {
            return @unionInit(T, f.name, try readValueImpl(reader, f.type, gpa));
        }
    }
    return error.InvalidData;
}

fn readCircular(reader: *Reader, comptime T: type, gpa: Allocator) Error!*T {
    const header = (try take(reader, 1))[0];
    if (header == 250) {
        const ref_id = try readTypeCode(reader);
        if (ref_id < 0) return error.InvalidData;
        const erased = reader.refs.get(@intCast(ref_id)) orelse return error.InvalidData;
        return @ptrCast(@alignCast(erased));
    }
    if (header == 255 or header > 249) return error.InvalidData;
    const count: usize = header;
    var lengths: [249]usize = undefined;
    for (lengths[0..count]) |*length| {
        const value = try readTypeCode(reader);
        if (value < 0) return error.InvalidData;
        length.* = @intCast(value);
    }
    const ref_id = try readTypeCode(reader);
    if (ref_id < 0) return error.InvalidData;
    const result = gpa.create(T) catch return error.OutOfMemory;
    errdefer gpa.destroy(result);
    try reader.refs.put(@intCast(ref_id), @ptrCast(result));
    var index: usize = 0;
    inline for (std.meta.fields(T)) |f| {
        if (index < count) {
            const start = reader.pos;
            @field(result.*, f.name) = try readValueImpl(reader, f.type, gpa);
            if (reader.pos - start > lengths[index]) return error.InvalidData;
            reader.pos = start + lengths[index];
        } else {
            @field(result.*, f.name) = std.mem.zeroes(f.type);
        }
        index += 1;
    }
    while (index < count) : (index += 1) _ = try take(reader, lengths[index]);
    return result;
}

pub const Writer = struct {
    list: std.ArrayList(u8) = .empty,
    gpa: Allocator,
    refs: std.AutoHashMap(usize, u64),
    shared_refs: ?*std.AutoHashMap(usize, u64) = null,
    next_ref_id: u64 = 0,
    shared_next_ref_id: ?*u64 = null,

    pub fn init(gpa: Allocator) Writer {
        return .{ .gpa = gpa, .refs = std.AutoHashMap(usize, u64).init(gpa) };
    }

    pub fn initWithRefs(gpa: Allocator, refs: *std.AutoHashMap(usize, u64), next_ref_id: *u64) Writer {
        return .{
            .gpa = gpa,
            .refs = std.AutoHashMap(usize, u64).init(gpa),
            .shared_refs = refs,
            .shared_next_ref_id = next_ref_id,
        };
    }

    pub fn refMap(self: *Writer) *std.AutoHashMap(usize, u64) {
        return self.shared_refs orelse &self.refs;
    }

    pub fn nextRefId(self: *Writer) *u64 {
        return self.shared_next_ref_id orelse &self.next_ref_id;
    }

    pub fn deinit(self: *Writer) void {
        self.list.deinit(self.gpa);
        if (self.shared_refs == null) self.refs.deinit();
    }

    pub fn toOwnedSlice(self: *Writer) Error![]u8 {
        return self.list.toOwnedSlice(self.gpa) catch error.OutOfMemory;
    }

    pub fn writeValue(self: *Writer, value: anytype) Error!void {
        return writeValueImpl(self, @TypeOf(value), value);
    }
};

pub const Reader = struct {
    buf: []const u8,
    pos: usize = 0,
    gpa: Allocator,
    refs: std.AutoHashMap(u64, *anyopaque),

    pub fn init(gpa: Allocator, buf: []const u8) Reader {
        return .{ .buf = buf, .gpa = gpa, .refs = std.AutoHashMap(u64, *anyopaque).init(gpa) };
    }

    pub fn deinit(self: *Reader) void {
        self.refs.deinit();
    }

    pub fn readValue(self: *Reader, comptime T: type) Error!T {
        return readValueImpl(self, T, self.gpa);
    }
};

pub fn encode(gpa: Allocator, value: anytype) Error![]u8 {
    var writer = Writer.init(gpa);
    errdefer writer.deinit();
    try writer.writeValue(value);
    const result = try writer.toOwnedSlice();
    writer.deinit();
    return result;
}

pub fn decode(comptime T: type, gpa: Allocator, bytes: []const u8) Error!T {
    var reader = Reader.init(gpa, bytes);
    defer reader.deinit();
    return reader.readValue(T);
}

pub fn encodeTo(gpa: Allocator, value: anytype, sink: anytype) Error!void {
    const bytes = try encode(gpa, value);
    defer gpa.free(bytes);
    sink.writeAll(bytes) catch return error.OutOfMemory;
}

pub fn decodeFromReader(comptime T: type, gpa: Allocator, reader: anytype) Error!T {
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(gpa);
    var chunk: [4096]u8 = undefined;
    while (true) {
        const count = reader.read(&chunk) catch return error.EndOfStream;
        if (count == 0) break;
        bytes.appendSlice(gpa, chunk[0..count]) catch return error.OutOfMemory;
    }
    return decode(T, gpa, bytes.items);
}

pub fn decodeInto(comptime T: type, gpa: Allocator, bytes: []const u8, target: *T) Error!void {
    var replacement = try decode(T, gpa, bytes);
    errdefer deinit(T, gpa, &replacement);
    if (comptime @typeInfo(T) == .pointer and @typeInfo(T).pointer.size == .slice and isFixed(@typeInfo(T).pointer.child)) {
        if (target.*.len == replacement.len) {
            std.mem.copyForwards(@typeInfo(T).pointer.child, @constCast(target.*), replacement);
            gpa.free(replacement);
            return;
        }
    }
    deinit(T, gpa, target);
    target.* = replacement;
}

fn deinitImpl(comptime T: type, gpa: Allocator, value: *T, seen: *std.AutoHashMap(usize, void)) void {
    if (comptime isStr(T)) {
        gpa.free(value.bytes);
        return;
    }
    if (comptime isBuiltin(T)) {
        if (comptime builtinKind(T).? == .uri) gpa.free(value.value.bytes);
        if (comptime builtinKind(T).? == .bit_array) gpa.free(value.bytes);
        if (comptime builtinKind(T).? == .string_builder) gpa.free(value.value.bytes);
        return;
    }
    if (comptime isMultiDimensional(T)) {
        gpa.free(value.values);
        return;
    }
    if (comptime isTuple(T)) {
        inline for (std.meta.fields(T)) |f| deinit(f.type, gpa, &@field(value.*, f.name));
        return;
    }
    switch (@typeInfo(T)) {
        .optional => |o| if (value.*) |*v| deinitImpl(o.child, gpa, v, seen),
        .pointer => |p| switch (p.size) {
            .slice => {
                for (value.*) |*item| deinitImpl(p.child, gpa, @constCast(item), seen);
                gpa.free(value.*);
            },
            .one => {
                const address = @intFromPtr(value.*);
                if (seen.contains(address)) return;
                seen.put(address, {}) catch return;
                deinitImpl(p.child, gpa, value.*, seen);
                gpa.destroy(value.*);
            },
            else => {},
        },
        .@"struct" => if (comptime isObject(T)) {
            inline for (std.meta.fields(T)) |f| deinitImpl(f.type, gpa, &@field(value.*, f.name), seen);
        },
        .@"union" => {
            const active = std.meta.activeTag(value.*);
            const Tag = @typeInfo(T).@"union".tag_type.?;
            inline for (std.meta.fields(T)) |f| {
                if (@intFromEnum(active) == @intFromEnum(@field(Tag, f.name))) {
                    deinitImpl(f.type, gpa, &@field(value.*, f.name), seen);
                }
            }
        },
        .array => |a| for (value) |*item| deinitImpl(a.child, gpa, item, seen),
        else => {},
    }
}

pub fn deinit(comptime T: type, gpa: Allocator, value: *T) void {
    var seen = std.AutoHashMap(usize, void).init(gpa);
    defer seen.deinit();
    deinitImpl(T, gpa, value, &seen);
}

const Padded = extern struct { a: u8, b: i32 };
const BasicObject = struct { id: i32, name: ?Str };
const NestedObject = struct { inner: ?BasicObject, values: ?[]const i32 };
const Level = enum(u8) { novice = 2, expert = 7 };
const RichObject = struct { id: u64, name: ?Str, data: ?[]const u8, level: Level, child: ?BasicObject };
const TuplePair = KeyValue(i32, Str);
const TextMessage = struct { value: ?Str };
const LargeMessage = struct { value: i32 };
const UnionTag = enum(u16) { number = 0, text = 1, large = 300 };
const MessageUnion = union(UnionTag) {
    number: BasicObject,
    text: TextMessage,
    large: LargeMessage,
};
const VersionV1 = struct {
    pub const memorypack_version_tolerant = true;
    id: i32,
};
const VersionV2 = struct {
    pub const memorypack_version_tolerant = true;
    id: i32,
    name: ?Str,
};
const VersionV3 = struct {
    pub const memorypack_version_tolerant = true;
    id: i32,
    name: ?Str,
    active: bool,
};
const CircularNode = struct {
    pub const memorypack_circular_reference = true;
    value: i32,
    next: ?*CircularNode,
};
const ExplicitObject = struct {
    pub const memorypack_explicit = true;
    pub const memorypack_explicit_count = 2;
    pub const memorypack_order_first = 0;
    pub const memorypack_order_third = 1;
    first: i32,
    third: ?Str,
};
const ExplicitGap = struct {
    pub const memorypack_explicit = true;
    pub const memorypack_explicit_count = 3;
    pub const memorypack_order_first = 0;
    pub const memorypack_order_third = 2;
    first: i32,
    third: ?Str,
};
const IntMatrix = Array2(i32);
const IntCube = Array(3, i32);
const Tuple3Value = Tuple3(i32, Str, bool);
const Tuple4Value = Tuple4(i32, Str, bool, f32);
const IgnoreObject = struct {
    pub const memorypack_ignore_ignored = true;
    kept: i32,
    ignored: i32,
};
const IncludeObject = struct {
    pub const memorypack_include_only = true;
    pub const memorypack_include_kept = true;
    pub const memorypack_include_included = true;
    kept: i32,
    included: i32,
};
var callback_log: [4]u8 = undefined;
var callback_index: usize = 0;
const CallbackObject = struct {
    value: i32,

    pub fn memorypackOnSerializing(_: *CallbackObject) void {
        callback_log[callback_index] = 1;
        callback_index += 1;
    }
    pub fn memorypackOnSerialized(_: *CallbackObject) void {
        callback_log[callback_index] = 2;
        callback_index += 1;
    }
    pub fn memorypackOnDeserializing(_: *CallbackObject) void {
        callback_log[callback_index] = 3;
        callback_index += 1;
    }
    pub fn memorypackOnDeserialized(_: *CallbackObject) void {
        callback_log[callback_index] = 4;
        callback_index += 1;
    }
};

fn checkVector(comptime T: type, gpa: Allocator, bytes: []const u8) !void {
    var decoded = try decode(T, gpa, bytes);
    defer deinit(T, gpa, &decoded);
    const encoded = try encode(gpa, decoded);
    defer gpa.free(encoded);
    try std.testing.expectEqualSlices(u8, bytes, encoded);
}

test "C# MemoryPack golden vectors" {
    const gpa = std.testing.allocator;
    try checkVector(BasicObject, gpa, @embedFile("vectors/object.bin"));
    try checkVector(BasicObject, gpa, @embedFile("vectors/object_null_string.bin"));
    try checkVector(NestedObject, gpa, @embedFile("vectors/nested.bin"));
    try checkVector(NestedObject, gpa, @embedFile("vectors/nested_null_collection.bin"));
    try checkVector(Padded, gpa, @embedFile("vectors/padded.bin"));
    try checkVector([]const i32, gpa, @embedFile("vectors/array_empty.bin"));
    try checkVector(?[]const i32, gpa, @embedFile("vectors/array_null.bin"));
    try checkVector(Str, gpa, @embedFile("vectors/string_empty.bin"));
    try checkVector(Str, gpa, @embedFile("vectors/string_unicode.bin"));
    try checkVector(?Str, gpa, @embedFile("vectors/string_null.bin"));
    try checkVector([]const u8, gpa, @embedFile("vectors/bytes.bin"));
    try checkVector(Level, gpa, @embedFile("vectors/enum.bin"));
    try checkVector(?i32, gpa, @embedFile("vectors/nullable_value.bin"));
    try checkVector(?i32, gpa, @embedFile("vectors/nullable_value_null.bin"));
    try checkVector(?BasicObject, gpa, @embedFile("vectors/nullable_object.bin"));
    try checkVector(RichObject, gpa, @embedFile("vectors/rich.bin"));
    try checkVector(TuplePair, gpa, @embedFile("vectors/tuple.bin"));
    try checkVector([]const TuplePair, gpa, @embedFile("vectors/dict_empty.bin"));
    try checkVector([]const TuplePair, gpa, @embedFile("vectors/dict_single.bin"));
    try checkVector([]const TuplePair, gpa, @embedFile("vectors/dict_multi.bin"));
    try checkVector(MessageUnion, gpa, @embedFile("vectors/union_small.bin"));
    try checkVector(MessageUnion, gpa, @embedFile("vectors/union_large.bin"));
    try checkVector(VersionV2, gpa, @embedFile("vectors/versioned.bin"));
    try checkVector(*CircularNode, gpa, @embedFile("vectors/circular.bin"));
    try checkVector(Guid, gpa, @embedFile("vectors/guid.bin"));
    try checkVector(DateTime, gpa, @embedFile("vectors/datetime.bin"));
    try checkVector(DateTimeOffset, gpa, @embedFile("vectors/datetimeoffset.bin"));
    try checkVector(TimeSpan, gpa, @embedFile("vectors/timespan.bin"));
    try checkVector(Decimal, gpa, @embedFile("vectors/decimal.bin"));
    try checkVector(Version, gpa, @embedFile("vectors/version.bin"));
    try checkVector(Uri, gpa, @embedFile("vectors/uri.bin"));
    try checkVector(ExplicitObject, gpa, @embedFile("vectors/explicit.bin"));
    try checkVector(i128, gpa, @embedFile("vectors/int128.bin"));
    try checkVector(u128, gpa, @embedFile("vectors/uint128.bin"));
    try checkVector(f16, gpa, @embedFile("vectors/half.bin"));
    try checkVector(IntMatrix, gpa, @embedFile("vectors/array_2d.bin"));
    try checkVector(IntCube, gpa, @embedFile("vectors/array_3d.bin"));
    try checkVector(Tuple3Value, gpa, @embedFile("vectors/tuple3.bin"));
    try checkVector(Tuple4Value, gpa, @embedFile("vectors/tuple4.bin"));
    try checkVector(DateOnly, gpa, @embedFile("vectors/date_only.bin"));
    try checkVector(TimeOnly, gpa, @embedFile("vectors/time_only.bin"));
    try checkVector([]const i32, gpa, @embedFile("vectors/linked_list.bin"));
    try checkVector([]const i32, gpa, @embedFile("vectors/queue.bin"));
    try checkVector([]const i32, gpa, @embedFile("vectors/stack.bin"));
    try checkVector([]const TuplePair, gpa, @embedFile("vectors/sorted_dictionary.bin"));
    try checkVector([]const i32, gpa, @embedFile("vectors/read_only_collection.bin"));
    try checkVector(IgnoreObject, gpa, @embedFile("vectors/ignore.bin"));
    try checkVector(IncludeObject, gpa, @embedFile("vectors/include.bin"));
    try checkVector(BitArray, gpa, @embedFile("vectors/bit_array.bin"));
    try checkVector(StringBuilder, gpa, @embedFile("vectors/string_builder.bin"));
    try checkVector(Complex, gpa, @embedFile("vectors/complex.bin"));
}

test "tuple, dictionary, union, and union escape" {
    const gpa = std.testing.allocator;
    const pair = TuplePair{ .key = 7, .value = .{ .bytes = "seven" } };
    const pair_bytes = try encode(gpa, pair);
    defer gpa.free(pair_bytes);
    var pair_back = try decode(TuplePair, gpa, pair_bytes);
    defer deinit(TuplePair, gpa, &pair_back);
    try std.testing.expectEqual(@as(i32, 7), pair_back.key);
    try std.testing.expectEqualStrings("seven", pair_back.value.bytes);

    const entries = [_]TuplePair{
        .{ .key = 1, .value = .{ .bytes = "one" } },
        .{ .key = 2, .value = .{ .bytes = "two" } },
    };
    const dict_bytes = try encode(gpa, entries[0..]);
    defer gpa.free(dict_bytes);
    var dict_back = try decode([]const TuplePair, gpa, dict_bytes);
    defer deinit([]const TuplePair, gpa, &dict_back);
    try std.testing.expectEqual(@as(usize, 2), dict_back.len);

    const empty_bytes = try encode(gpa, @as([]const TuplePair, &.{}));
    defer gpa.free(empty_bytes);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0, 0, 0, 0 }, empty_bytes);
    const null_bytes = try encode(gpa, @as(?[]const TuplePair, null));
    defer gpa.free(null_bytes);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0xff, 0xff, 0xff, 0xff }, null_bytes);

    const small = MessageUnion{ .text = .{ .value = .{ .bytes = "hi" } } };
    const small_bytes = try encode(gpa, small);
    defer gpa.free(small_bytes);
    try std.testing.expectEqual(@as(u8, 1), small_bytes[0]);
    var small_back = try decode(MessageUnion, gpa, small_bytes);
    defer deinit(MessageUnion, gpa, &small_back);
    try std.testing.expectEqualStrings("hi", small_back.text.value.?.bytes);

    const large = MessageUnion{ .large = .{ .value = 4 } };
    const large_bytes = try encode(gpa, large);
    defer gpa.free(large_bytes);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 250, 44, 1 }, large_bytes[0..3]);
    var large_back = try decode(MessageUnion, gpa, large_bytes);
    defer deinit(MessageUnion, gpa, &large_back);
    try std.testing.expectEqual(@as(i32, 4), large_back.large.value);

    const union_null = try encode(gpa, @as(?MessageUnion, null));
    defer gpa.free(union_null);
    try std.testing.expectEqualSlices(u8, &[_]u8{255}, union_null);
}

test "typecode varint boundaries" {
    const gpa = std.testing.allocator;
    const values = [_]i64{
        0,
        127,
        128,
        255,
        256,
        65535,
        65536,
        4294967295,
        4294967296,
        9223372036854775807,
        -1,
        -120,
        -121,
        -128,
        -129,
        -32768,
        -32769,
        -2147483648,
        -2147483649,
        -9223372036854775807 - 1,
    };
    for (values) |expected| {
        var writer = Writer.init(gpa);
        defer writer.deinit();
        try writeTypeCode(&writer, expected);
        const bytes = try writer.toOwnedSlice();
        defer gpa.free(bytes);
        var reader = Reader.init(gpa, bytes);
        defer reader.deinit();
        try std.testing.expectEqual(expected, try readTypeCode(&reader));
    }
}

test "version tolerant object evolves across schemas" {
    const gpa = std.testing.allocator;
    const v2 = VersionV2{ .id = 7, .name = .{ .bytes = "new" } };
    const bytes = try encode(gpa, v2);
    defer gpa.free(bytes);
    var old = try decode(VersionV1, gpa, bytes);
    defer deinit(VersionV1, gpa, &old);
    try std.testing.expectEqual(@as(i32, 7), old.id);
    var current = try decode(VersionV3, gpa, bytes);
    defer deinit(VersionV3, gpa, &current);
    try std.testing.expectEqual(@as(i32, 7), current.id);
    try std.testing.expectEqualStrings("new", current.name.?.bytes);
    try std.testing.expect(!current.active);

    const v1 = try encode(gpa, VersionV1{ .id = 9 });
    defer gpa.free(v1);
    var newer = try decode(VersionV3, gpa, v1);
    defer deinit(VersionV3, gpa, &newer);
    try std.testing.expectEqual(@as(i32, 9), newer.id);
    try std.testing.expect(newer.name == null);
}

test "circular reference object preserves identity" {
    const gpa = std.testing.allocator;
    const node = try gpa.create(CircularNode);
    node.* = .{ .value = 42, .next = node };
    const bytes = try encode(gpa, node);
    defer gpa.free(bytes);
    defer gpa.destroy(node);
    var decoded = try decode(*CircularNode, gpa, bytes);
    defer deinit(*CircularNode, gpa, &decoded);
    try std.testing.expectEqual(@as(i32, 42), decoded.value);
    try std.testing.expect(decoded.next.? == decoded);
}

test "explicit layout and callbacks" {
    const gpa = std.testing.allocator;
    const value = ExplicitObject{ .first = 7, .third = .{ .bytes = "gap" } };
    const bytes = try encode(gpa, value);
    defer gpa.free(bytes);
    var decoded = try decode(ExplicitObject, gpa, bytes);
    defer deinit(ExplicitObject, gpa, &decoded);
    try std.testing.expectEqual(@as(i32, 7), decoded.first);
    try std.testing.expectEqualStrings("gap", decoded.third.?.bytes);

    const gap = try encode(gpa, ExplicitGap{ .first = 7, .third = .{ .bytes = "gap" } });
    defer gpa.free(gap);
    try std.testing.expectEqual(@as(u8, 3), gap[0]);
    try std.testing.expectEqual(@as(u8, 0), gap[5]);

    callback_index = 0;
    const callback_bytes = try encode(gpa, CallbackObject{ .value = 9 });
    defer gpa.free(callback_bytes);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 1, 2 }, callback_log[0..2]);
    callback_index = 0;
    var callback_value = try decode(CallbackObject, gpa, callback_bytes);
    defer deinit(CallbackObject, gpa, &callback_value);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 3, 4 }, callback_log[0..2]);
}

test "multi-dimensional and member selection formats" {
    const gpa = std.testing.allocator;
    const matrix = IntMatrix{ .dimensions = .{ 2, 2 }, .values = &.{ 1, 2, 3, 4 } };
    const matrix_bytes = try encode(gpa, matrix);
    defer gpa.free(matrix_bytes);
    var decoded_matrix = try decode(IntMatrix, gpa, matrix_bytes);
    defer deinit(IntMatrix, gpa, &decoded_matrix);
    try std.testing.expectEqualSlices(i32, &.{ 1, 2, 3, 4 }, decoded_matrix.values);

    const cube = IntCube{ .dimensions = .{ 2, 2, 2 }, .values = &.{ 1, 2, 3, 4, 5, 6, 7, 8 } };
    const cube_bytes = try encode(gpa, cube);
    defer gpa.free(cube_bytes);
    var decoded_cube = try decode(IntCube, gpa, cube_bytes);
    defer deinit(IntCube, gpa, &decoded_cube);
    try std.testing.expectEqualSlices(i32, &.{ 1, 2, 3, 4, 5, 6, 7, 8 }, decoded_cube.values);

    const ignored = try encode(gpa, IgnoreObject{ .kept = 7, .ignored = 99 });
    defer gpa.free(ignored);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 1, 7, 0, 0, 0 }, ignored);
    var decoded_ignored = try decode(IgnoreObject, gpa, ignored);
    defer deinit(IgnoreObject, gpa, &decoded_ignored);
    try std.testing.expectEqual(@as(i32, 0), decoded_ignored.ignored);

    const included = try encode(gpa, IncludeObject{ .kept = 7, .included = 11 });
    defer gpa.free(included);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 2, 7, 0, 0, 0, 11, 0, 0, 0 }, included);
}

test "streaming APIs match buffer APIs and reuse slices" {
    const gpa = std.testing.allocator;
    const value = BasicObject{ .id = 42, .name = .{ .bytes = "stream" } };
    const expected = try encode(gpa, value);
    defer gpa.free(expected);

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(gpa);
    const Sink = struct {
        list: *std.ArrayList(u8),
        gpa: Allocator,
        pub fn writeAll(self: @This(), bytes: []const u8) !void {
            try self.list.appendSlice(self.gpa, bytes);
        }
    };
    try encodeTo(gpa, value, Sink{ .list = &output, .gpa = gpa });
    try std.testing.expectEqualSlices(u8, expected, output.items);
    output.clearRetainingCapacity();
    const primitive = try encode(gpa, @as(i32, 1234));
    defer gpa.free(primitive);
    try encodeTo(gpa, @as(i32, 1234), Sink{ .list = &output, .gpa = gpa });
    try std.testing.expectEqualSlices(u8, primitive, output.items);
    output.clearRetainingCapacity();
    const collection = try encode(gpa, @as([]const i32, &.{ 1, 2, 3 }));
    defer gpa.free(collection);
    try encodeTo(gpa, @as([]const i32, &.{ 1, 2, 3 }), Sink{ .list = &output, .gpa = gpa });
    try std.testing.expectEqualSlices(u8, collection, output.items);
    output.clearRetainingCapacity();
    const string = try encode(gpa, Str{ .bytes = "stream string" });
    defer gpa.free(string);
    try encodeTo(gpa, Str{ .bytes = "stream string" }, Sink{ .list = &output, .gpa = gpa });
    try std.testing.expectEqualSlices(u8, string, output.items);
    output.clearRetainingCapacity();
    const versioned = try encode(gpa, VersionV2{ .id = 9, .name = .{ .bytes = "v" } });
    defer gpa.free(versioned);
    try encodeTo(gpa, VersionV2{ .id = 9, .name = .{ .bytes = "v" } }, Sink{ .list = &output, .gpa = gpa });
    try std.testing.expectEqualSlices(u8, versioned, output.items);

    const ChunkReader = struct {
        bytes: []const u8,
        pos: usize = 0,
        pub fn read(self: *@This(), dest: []u8) !usize {
            const count = @min(dest.len, self.bytes.len - self.pos);
            @memcpy(dest[0..count], self.bytes[self.pos..][0..count]);
            self.pos += count;
            return count;
        }
    };
    var source = ChunkReader{ .bytes = expected };
    var decoded = try decodeFromReader(BasicObject, gpa, &source);
    defer deinit(BasicObject, gpa, &decoded);
    try std.testing.expectEqual(@as(i32, 42), decoded.id);

    const original = try gpa.alloc(i32, 3);
    original[0] = 1;
    original[1] = 2;
    original[2] = 3;
    var slice: []const i32 = original;
    const replacement_bytes = try encode(gpa, @as([]const i32, &.{ 4, 5, 6 }));
    defer gpa.free(replacement_bytes);
    try decodeInto([]const i32, gpa, replacement_bytes, &slice);
    defer deinit([]const i32, gpa, &slice);
    try std.testing.expect(@intFromPtr(slice.ptr) == @intFromPtr(original.ptr));
    try std.testing.expectEqualSlices(i32, &.{ 4, 5, 6 }, slice);
}
