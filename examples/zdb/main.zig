const std = @import("std");
const zdb = @import("zdb");
const memorypack = @import("memorypack");

fn parseStatus(value: []const u8) !zdb.Status {
    if (std.mem.eql(u8, value, "draft")) return .draft;
    if (std.mem.eql(u8, value, "active")) return .active;
    if (std.mem.eql(u8, value, "archived")) return .archived;
    return error.InvalidStatus;
}

fn parseId(value: []const u8) !i32 {
    return std.fmt.parseInt(i32, value, 10);
}

fn printDocument(document: zdb.Document) void {
    std.debug.print("#{d} [{s}] {s} score={d}", .{
        document.id,
        @tagName(document.status),
        document.name.bytes,
        document.score,
    });
    if (document.due) |due| std.debug.print(" due={d}", .{due});
    if (document.tags.len > 0) {
        std.debug.print(" tags=", .{});
        for (document.tags, 0..) |tag, index| {
            if (index > 0) std.debug.print(",", .{});
            std.debug.print("{s}", .{tag.bytes});
        }
    }
    std.debug.print("\n", .{});
}

fn printStore(store: *zdb.Store, allocator: std.mem.Allocator) !void {
    var ids: std.ArrayList(i32) = .empty;
    defer ids.deinit(allocator);
    var iterator = store.documents.valueIterator();
    while (iterator.next()) |document| try ids.append(allocator, document.id);
    for (ids.items, 0..) |*id, index| {
        for (ids.items[index + 1 ..]) |*other| {
            if (other.* < id.*) std.mem.swap(i32, id, other);
        }
    }
    for (ids.items) |id| printDocument(store.get(id).?);
}

fn hasTag(document: zdb.Document, wanted: []const u8) bool {
    for (document.tags) |tag| {
        if (std.mem.eql(u8, tag.bytes, wanted)) return true;
    }
    return false;
}

fn put(
    store: *zdb.Store,
    allocator: std.mem.Allocator,
    args: *std.process.Args.Iterator,
) !void {
    const id = try parseId(args.next() orelse return error.MissingId);
    const name = args.next() orelse return error.MissingName;
    var status: zdb.Status = .active;
    var score: i64 = 0;
    var due: ?i32 = null;
    var tags: std.ArrayList(memorypack.Str) = .empty;
    defer tags.deinit(allocator);
    while (args.next()) |option| {
        if (std.mem.eql(u8, option, "--status")) {
            status = try parseStatus(args.next() orelse return error.MissingStatus);
        } else if (std.mem.eql(u8, option, "--score")) {
            score = try std.fmt.parseInt(i64, args.next() orelse return error.MissingScore, 10);
        } else if (std.mem.eql(u8, option, "--due")) {
            due = try parseId(args.next() orelse return error.MissingDue);
        } else if (std.mem.eql(u8, option, "--tags")) {
            var parts = std.mem.splitScalar(u8, args.next() orelse return error.MissingTags, ',');
            while (parts.next()) |part| {
                if (part.len == 0) continue;
                try tags.append(allocator, .{ .bytes = part });
            }
        } else {
            return error.UnknownOption;
        }
    }
    try store.put(.{
        .id = id,
        .name = .{ .bytes = name },
        .status = status,
        .score = score,
        .due = due,
        .tags = tags.items,
    });
    std.debug.print("put #{d}\n", .{id});
}

fn query(store: *zdb.Store, allocator: std.mem.Allocator, args: *std.process.Args.Iterator) !void {
    var status: ?zdb.Status = null;
    var tag: ?[]const u8 = null;
    while (args.next()) |option| {
        if (std.mem.eql(u8, option, "--status")) {
            status = try parseStatus(args.next() orelse return error.MissingStatus);
        } else if (std.mem.eql(u8, option, "--tag")) {
            tag = args.next() orelse return error.MissingTag;
        } else {
            return error.UnknownOption;
        }
    }
    if (status) |wanted| {
        var ids: std.ArrayList(i32) = .empty;
        defer ids.deinit(allocator);
        try store.queryStatus(wanted, &ids);
        std.debug.print("query status={s} (secondary index)\n", .{@tagName(wanted)});
        for (ids.items) |id| printDocument(store.get(id).?);
    } else if (tag) |wanted| {
        std.debug.print("query tag={s}\n", .{wanted});
        var iterator = store.documents.valueIterator();
        while (iterator.next()) |document| {
            if (hasTag(document.*, wanted)) printDocument(document.*);
        }
    } else {
        return error.MissingQuery;
    }
}

pub fn main(init: std.process.Init) !void {
    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.next() orelse return error.InvalidData;
    const directory = args.next() orelse ".zdb";
    const command = args.next() orelse return error.MissingCommand;
    const allocator = std.heap.page_allocator;
    var store = try zdb.Store.open(init.io, allocator, directory);
    defer store.deinit();

    if (std.mem.eql(u8, command, "put")) {
        try put(&store, allocator, &args);
    } else if (std.mem.eql(u8, command, "get")) {
        const id = try parseId(args.next() orelse return error.MissingId);
        if (args.next() != null) return error.UnknownOption;
        if (store.get(id)) |document| printDocument(document);
    } else if (std.mem.eql(u8, command, "delete")) {
        const id = try parseId(args.next() orelse return error.MissingId);
        if (args.next() != null) return error.UnknownOption;
        try store.delete(id);
        std.debug.print("deleted #{d}\n", .{id});
    } else if (std.mem.eql(u8, command, "query")) {
        try query(&store, allocator, &args);
    } else if (std.mem.eql(u8, command, "list")) {
        if (args.next() != null) return error.UnknownOption;
        try printStore(&store, allocator);
    } else if (std.mem.eql(u8, command, "compact")) {
        if (args.next() != null) return error.UnknownOption;
        try store.compact();
        std.debug.print("compacted snapshot_version={d}, wal_frames={d}\n", .{
            store.snapshot_version,
            store.wal_frames,
        });
    } else if (std.mem.eql(u8, command, "stats")) {
        if (args.next() != null) return error.UnknownOption;
        std.debug.print("documents={d}, snapshot_version={d}, wal_frames={d}\n", .{
            store.count(),
            store.snapshot_version,
            store.wal_frames,
        });
    } else {
        return error.UnknownCommand;
    }
}
