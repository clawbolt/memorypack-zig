const std = @import("std");
const memorypack = @import("memorypack");

const PlayerLevel = enum(u8) {
    novice = 1,
    veteran = 2,
    champion = 3,
};

const Rarity = enum(u8) {
    common = 1,
    rare = 2,
    legendary = 3,
};

const InventoryItem = struct {
    name: memorypack.Str,
    count: i32,
    rarity: Rarity,
};

const LevelUpEvent = struct {
    level: i32,
};

const ItemFoundEvent = struct {
    item_name: memorypack.Str,
    count: i32,
};

const EventTag = enum(u16) {
    level_up = 0,
    item_found = 1,
};

const PlayerEvent = union(EventTag) {
    level_up: LevelUpEvent,
    item_found: ItemFoundEvent,
};

const PlayerProfile = struct {
    id: i32,
    name: memorypack.Str,
    level: PlayerLevel,
    experience: i64,
    last_login: ?i32,
    inventory: []const InventoryItem,
    recent_events: []const PlayerEvent,
};

fn profile() PlayerProfile {
    return .{
        .id = 1001,
        .name = .{ .bytes = "Ada" },
        .level = .veteran,
        .experience = 123450,
        .last_login = 12345,
        .inventory = &.{
            .{ .name = .{ .bytes = "Moonblade" }, .count = 1, .rarity = .legendary },
            .{ .name = .{ .bytes = "Potion" }, .count = 5, .rarity = .common },
        },
        .recent_events = &.{
            .{ .level_up = .{ .level = 2 } },
            .{ .item_found = .{ .item_name = .{ .bytes = "Moonblade" }, .count = 1 } },
        },
    };
}

fn readFile(io: std.Io, allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(1024 * 1024));
}

fn writeFile(io: std.Io, path: []const u8, bytes: []const u8) !void {
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = bytes });
}

fn printProfile(label: []const u8, value: PlayerProfile) void {
    std.debug.print("{s}: id={d}, name={s}, level={s}, xp={d}, lastLoginDay={d}, inventory={d}, events={d}\n", .{
        label,
        value.id,
        value.name.bytes,
        @tagName(value.level),
        value.experience,
        value.last_login.?,
        value.inventory.len,
        value.recent_events.len,
    });
    for (value.inventory) |item| {
        std.debug.print("  inventory: {s} x{d} ({s})\n", .{
            item.name.bytes,
            item.count,
            @tagName(item.rarity),
        });
    }
    for (value.recent_events) |event| {
        switch (event) {
            .level_up => |item| std.debug.print("  event: level-up -> {d}\n", .{item.level}),
            .item_found => |item| std.debug.print("  event: item-found {s} x{d}\n", .{
                item.item_name.bytes,
                item.count,
            }),
        }
    }
}

fn writeProfile(io: std.Io, allocator: std.mem.Allocator, path: []const u8) !void {
    const value = profile();
    const bytes = try memorypack.encode(allocator, value);
    defer allocator.free(bytes);
    try writeFile(io, path, bytes);
    printProfile("Zig wrote profile", value);
    std.debug.print("  bytes written: {d} -> {s}\n", .{ bytes.len, path });
}

fn readUpdatedProfile(io: std.Io, allocator: std.mem.Allocator, path: []const u8) !void {
    const bytes = try readFile(io, allocator, path);
    defer allocator.free(bytes);
    var value = try memorypack.decode(PlayerProfile, allocator, bytes);
    defer memorypack.deinit(PlayerProfile, allocator, &value);
    printProfile("Zig read updated profile", value);
    std.debug.assert(value.level == .champion);
    std.debug.assert(value.inventory.len == 3);
    std.debug.assert(value.inventory[2].name.bytes.len == "Phoenix Down".len);
    std.debug.assert(value.recent_events.len == 3);
    switch (value.recent_events[2]) {
        .level_up => |event| std.debug.assert(event.level == 3),
        else => std.debug.assert(false),
    }
    std.debug.print("  mutation assertions: passed\n", .{});
}

pub fn main(init: std.process.Init) !void {
    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.next() orelse return error.InvalidData;
    const mode = args.next() orelse return error.InvalidData;
    const path = args.next() orelse return error.InvalidData;
    if (args.next() != null) return error.InvalidData;
    const allocator = std.heap.page_allocator;
    if (std.mem.eql(u8, mode, "write")) {
        try writeProfile(init.io, allocator, path);
    } else if (std.mem.eql(u8, mode, "read")) {
        try readUpdatedProfile(init.io, allocator, path);
    } else {
        return error.InvalidData;
    }
}
