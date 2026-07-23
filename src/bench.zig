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
    var raw_len: usize = 0;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    for (0..iterations) |_| {
        _ = arena.reset(.retain_capacity);
        const bench_gpa = arena.allocator();
        const raw_bytes = try memorypack.encode(bench_gpa, raw);
        raw_len = raw_bytes.len;
        const decoded = try memorypack.decode([64]Raw, bench_gpa, raw_bytes);
        _ = decoded;
    }
    const raw_ns = nowNs() - timer;
    report("MemoryPack unmanaged", raw_ns, raw_len, iterations);

    timer = nowNs();
    var object_len: usize = 0;
    for (0..iterations) |_| {
        _ = arena.reset(.retain_capacity);
        const bench_gpa = arena.allocator();
        const object_bytes = try memorypack.encode(bench_gpa, object);
        object_len = object_bytes.len;
        var decoded = try memorypack.decode([64]Object, bench_gpa, object_bytes);
        memorypack.deinit([64]Object, bench_gpa, &decoded);
    }
    const object_ns = nowNs() - timer;
    report("MemoryPack object", object_ns, object_len, iterations);

    timer = nowNs();
    var json_len: usize = 0;
    for (0..iterations) |_| {
        _ = arena.reset(.retain_capacity);
        const bench_gpa = arena.allocator();
        const json_bytes = try std.json.Stringify.valueAlloc(bench_gpa, json_object, .{});
        json_len = json_bytes.len;
        var parsed = try std.json.parseFromSlice([64]JsonObject, bench_gpa, json_bytes, .{});
        parsed.deinit();
    }
    const json_ns = nowNs() - timer;
    report("std.json", json_ns, json_len, iterations);
}
