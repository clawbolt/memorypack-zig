const std = @import("std");
const memorypack = @import("memorypack");

const Vec3 = extern struct { x: f32, y: f32, z: f32 };
const Player = struct {
    id: u64,
    name: []const u8,
    position: Vec3,
    health: ?f32,
    level: enum(u8) { novice, expert },
};

pub fn main() !void {
    const gpa = std.heap.page_allocator;
    const player = Player{
        .id = 0x1234,
        .name = "Ada",
        .position = .{ .x = 1.5, .y = -2, .z = 3.25 },
        .health = 87.5,
        .level = .expert,
    };
    const bytes = try memorypack.encode(gpa, player);
    defer gpa.free(bytes);
    var round_trip = try memorypack.decode(Player, gpa, bytes);
    defer memorypack.deinit(Player, gpa, &round_trip);
    std.debug.print("encoded {d} bytes; id={d}, name={s}, position=({d}, {d}, {d}), health={d}, level={s}\n", .{
        bytes.len, round_trip.id, round_trip.name, round_trip.position.x, round_trip.position.y, round_trip.position.z, round_trip.health.?, @tagName(round_trip.level),
    });
}
