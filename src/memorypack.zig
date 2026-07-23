const std = @import("std");
const builtin = @import("builtin");

pub const Error = error{ EndOfStream, InvalidData, OutOfMemory };
const Allocator = std.mem.Allocator;

pub const Str = struct {
    bytes: []const u8,
};

pub fn KeyValue(comptime K: type, comptime V: type) type {
    return struct {
        pub const memorypack_tuple = true;
        key: K,
        value: V,
    };
}

pub fn Dictionary(comptime K: type, comptime V: type) type {
    return []const KeyValue(K, V);
}

fn isStr(comptime T: type) bool {
    return T == Str;
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

fn isFixed(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .bool, .int, .float, .@"enum" => true,
        .array => |a| isFixed(a.child),
        .@"struct" => |s| blk: {
            if (s.layout != .@"extern" or isStr(T) or isTuple(T)) break :blk false;
            inline for (std.meta.fields(T)) |f| {
                if (!isFixed(f.type)) break :blk false;
            }
            break :blk true;
        },
        else => false,
    };
}

fn isObject(comptime T: type) bool {
    return @typeInfo(T) == .@"struct" and !isStr(T) and !isTuple(T) and !isFixed(T);
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
    if (comptime isTuple(T)) return writeTuple(writer, T, value);
    if (comptime isVersionTolerant(T)) return writeVersionTolerant(writer, T, value);
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
                if (std.meta.fields(T).len > 249) @compileError("MemoryPack object member count exceeds 249");
                try append(writer, &[_]u8{@intCast(std.meta.fields(T).len)});
                inline for (std.meta.fields(T)) |f| try writeValueImpl(writer, f.type, @field(value, f.name));
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
    if (comptime isTuple(T)) {
        var result: T = undefined;
        inline for (std.meta.fields(T)) |f| {
            @field(result, f.name) = try readValueImpl(reader, f.type, gpa);
        }
        return result;
    }
    if (comptime isVersionTolerant(T)) return readVersionTolerant(reader, T, gpa);
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
                if (header != std.meta.fields(o.child).len) return error.InvalidData;
                var result: o.child = undefined;
                inline for (std.meta.fields(o.child)) |f| @field(result, f.name) = try readValueImpl(reader, f.type, gpa);
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
                if (header == 255 or header != std.meta.fields(T).len) return error.InvalidData;
                inline for (std.meta.fields(T)) |f| @field(result, f.name) = try readValueImpl(reader, f.type, gpa);
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

fn deinitImpl(comptime T: type, gpa: Allocator, value: *T, seen: *std.AutoHashMap(usize, void)) void {
    if (comptime isStr(T)) {
        gpa.free(value.bytes);
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
