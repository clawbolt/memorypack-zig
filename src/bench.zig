const std = @import("std");
const memorypack = @import("memorypack");

const Raw = extern struct {
    a: u64,
    b: i64,
    c: f64,
};

const Object = struct {
    id: i32,
    name: memorypack.Str,
    values: [4]i32,
};

const JsonObject = struct {
    id: i32,
    name: []const u8,
    values: [4]i32,
};

fn report(name: []const u8, elapsed_ns: u64, bytes: usize, iterations: usize) void {
    const seconds = @as(f64, @floatFromInt(elapsed_ns)) / std.time.ns_per_s;
    const mib = (@as(f64, @floatFromInt(bytes * iterations)) / (1024.0 * 1024.0));
    std.debug.print("{s}: {d:.2} MiB/s ({d:.0} ns/op, {d} bytes/op)\n", .{
        name,
        mib / seconds,
        @as(f64, @floatFromInt(elapsed_ns)) / @as(f64, @floatFromInt(iterations)),
        bytes,
    });
}

fn nowNs() u64 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(std.os.linux.CLOCK.MONOTONIC, &ts);
    return @intCast(ts.sec * std.time.ns_per_s + ts.nsec);
}

pub fn main() !void {
    const gpa = std.heap.page_allocator;
    const iterations: usize = 2000;
    var raw: [64]Raw = undefined;
    for (&raw, 0..) |*item, i| item.* = .{ .a = i, .b = -@as(i64, @intCast(i)), .c = @floatFromInt(i) };
    var object: [64]Object = undefined;
    for (&object, 0..) |*item, i| item.* = .{
        .id = @intCast(i),
        .name = .{ .bytes = "benchmark" },
        .values = .{ 1, 2, 3, 4 },
    };
    var json_object: [64]JsonObject = undefined;
    for (&json_object, 0..) |*item, i| item.* = .{
        .id = @intCast(i),
        .name = "benchmark",
        .values = .{ 1, 2, 3, 4 },
    };

    var timer = nowNs();
    var raw_bytes: []u8 = &.{};
    for (0..iterations) |_| {
        if (raw_bytes.len != 0) gpa.free(raw_bytes);
        raw_bytes = try memorypack.encode(gpa, raw);
        const decoded = try memorypack.decode([64]Raw, gpa, raw_bytes);
        _ = decoded;
    }
    const raw_ns = nowNs() - timer;
    defer if (raw_bytes.len != 0) gpa.free(raw_bytes);
    report("MemoryPack unmanaged", raw_ns, raw_bytes.len, iterations);

    timer = nowNs();
    var object_bytes: []u8 = &.{};
    for (0..iterations) |_| {
        if (object_bytes.len != 0) gpa.free(object_bytes);
        object_bytes = try memorypack.encode(gpa, object);
        var decoded = try memorypack.decode([64]Object, gpa, object_bytes);
        memorypack.deinit([64]Object, gpa, &decoded);
    }
    const object_ns = nowNs() - timer;
    defer if (object_bytes.len != 0) gpa.free(object_bytes);
    report("MemoryPack object", object_ns, object_bytes.len, iterations);

    timer = nowNs();
    var json_bytes: []u8 = &.{};
    for (0..iterations) |_| {
        if (json_bytes.len != 0) gpa.free(json_bytes);
        json_bytes = try std.json.Stringify.valueAlloc(gpa, json_object, .{});
        var parsed = try std.json.parseFromSlice([64]JsonObject, gpa, json_bytes, .{});
        parsed.deinit();
    }
    const json_ns = nowNs() - timer;
    defer if (json_bytes.len != 0) gpa.free(json_bytes);
    report("std.json", json_ns, json_bytes.len, iterations);
}
