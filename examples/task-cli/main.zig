const std = @import("std");
const memorypack = @import("memorypack");

const Priority = enum(u8) {
    low = 0,
    normal = 1,
    high = 2,
};

const Status = enum(u8) {
    open = 0,
    done = 1,
};

const Task = struct {
    pub const memorypack_version_tolerant = true;

    id: i32,
    title: memorypack.Str,
    priority: Priority,
    status: Status,
    due: ?i32,
};

const Store = struct {
    pub const memorypack_version_tolerant = true;

    next_id: i32,
    tasks: []Task,
};

const LegacyTask = struct {
    pub const memorypack_version_tolerant = true;

    id: i32,
    title: memorypack.Str,
    priority: Priority,
    status: Status,
};

const LegacyStore = struct {
    pub const memorypack_version_tolerant = true;

    next_id: i32,
    tasks: []LegacyTask,
};

fn readFile(io: std.Io, allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(16 * 1024 * 1024));
}

fn writeFile(io: std.Io, path: []const u8, bytes: []const u8) !void {
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = bytes });
}

fn emptyStore(allocator: std.mem.Allocator) !Store {
    return .{ .next_id = 1, .tasks = try allocator.alloc(Task, 0) };
}

fn loadStore(io: std.Io, allocator: std.mem.Allocator, path: []const u8) !Store {
    const bytes = readFile(io, allocator, path) catch |err| switch (err) {
        error.FileNotFound => return emptyStore(allocator),
        else => return err,
    };
    defer allocator.free(bytes);
    return memorypack.decode(Store, allocator, bytes);
}

fn saveStore(io: std.Io, allocator: std.mem.Allocator, path: []const u8, store: Store) !void {
    const bytes = try memorypack.encode(allocator, store);
    defer allocator.free(bytes);
    try writeFile(io, path, bytes);
}

fn parsePriority(value: []const u8) !Priority {
    if (std.mem.eql(u8, value, "low")) return .low;
    if (std.mem.eql(u8, value, "normal")) return .normal;
    if (std.mem.eql(u8, value, "high")) return .high;
    return error.InvalidPriority;
}

fn parseId(value: []const u8) !i32 {
    return std.fmt.parseInt(i32, value, 10);
}

fn priorityName(value: Priority) []const u8 {
    return @tagName(value);
}

fn statusName(value: Status) []const u8 {
    return @tagName(value);
}

fn printStore(store: Store) void {
    if (store.tasks.len == 0) {
        std.debug.print("No tasks.\n", .{});
        return;
    }
    for (store.tasks) |task| {
        if (task.due) |day| {
            std.debug.print("#{d} [{s}] [{s}] {s} (due day {d})\n", .{
                task.id,
                statusName(task.status),
                priorityName(task.priority),
                task.title.bytes,
                day,
            });
        } else {
            std.debug.print("#{d} [{s}] [{s}] {s}\n", .{
                task.id,
                statusName(task.status),
                priorityName(task.priority),
                task.title.bytes,
            });
        }
    }
}

fn addTask(
    allocator: std.mem.Allocator,
    store: *Store,
    title: []const u8,
    priority: Priority,
    due: ?i32,
) !void {
    const new_tasks = try allocator.realloc(store.tasks, store.tasks.len + 1);
    store.tasks = new_tasks;
    store.tasks[store.tasks.len - 1] = .{
        .id = store.next_id,
        .title = .{ .bytes = try allocator.dupe(u8, title) },
        .priority = priority,
        .status = .open,
        .due = due,
    };
    store.next_id += 1;
    std.debug.print("Added task #{d}: {s}\n", .{ store.tasks[store.tasks.len - 1].id, title });
}

fn markDone(allocator: std.mem.Allocator, store: *Store, id: i32) !void {
    _ = allocator;
    for (store.tasks) |*task| {
        if (task.id == id) {
            task.status = .done;
            std.debug.print("Completed task #{d}.\n", .{id});
            return;
        }
    }
    std.debug.print("Task #{d} not found.\n", .{id});
    return error.TaskNotFound;
}

fn removeTask(allocator: std.mem.Allocator, store: *Store, id: i32) !void {
    for (store.tasks, 0..) |*task, index| {
        if (task.id != id) continue;
        const old_tasks = store.tasks;
        const new_tasks = try allocator.alloc(Task, old_tasks.len - 1);
        memorypack.deinit(Task, allocator, task);
        @memcpy(new_tasks[0..index], old_tasks[0..index]);
        @memcpy(new_tasks[index..], old_tasks[index + 1 ..]);
        allocator.free(old_tasks);
        store.tasks = new_tasks;
        std.debug.print("Removed task #{d}.\n", .{id});
        return;
    }
    std.debug.print("Task #{d} not found.\n", .{id});
    return error.TaskNotFound;
}

fn runCommand(
    io: std.Io,
    allocator: std.mem.Allocator,
    store_path: []const u8,
    command: []const u8,
    command_args: *std.process.Args.Iterator,
) !void {
    var store = try loadStore(io, allocator, store_path);
    defer memorypack.deinit(Store, allocator, &store);

    if (std.mem.eql(u8, command, "add")) {
        const title = command_args.next() orelse return error.MissingTitle;
        var priority: Priority = .normal;
        var due: ?i32 = null;
        while (command_args.next()) |option| {
            if (std.mem.eql(u8, option, "--priority")) {
                priority = try parsePriority(command_args.next() orelse return error.MissingPriority);
            } else if (std.mem.eql(u8, option, "--due")) {
                due = try parseId(command_args.next() orelse return error.MissingDue);
            } else {
                return error.UnknownOption;
            }
        }
        try addTask(allocator, &store, title, priority, due);
    } else if (std.mem.eql(u8, command, "list")) {
        if (command_args.next() != null) return error.UnknownOption;
        printStore(store);
        return;
    } else if (std.mem.eql(u8, command, "done")) {
        try markDone(allocator, &store, try parseId(command_args.next() orelse return error.MissingId));
    } else if (std.mem.eql(u8, command, "rm")) {
        try removeTask(allocator, &store, try parseId(command_args.next() orelse return error.MissingId));
    } else {
        return error.UnknownCommand;
    }
    if (command_args.next() != null) return error.UnknownOption;
    try saveStore(io, allocator, store_path, store);
}

fn writeLegacy(io: std.Io, allocator: std.mem.Allocator, path: []const u8) !void {
    var tasks = [_]LegacyTask{.{
        .id = 1,
        .title = .{ .bytes = "Legacy task" },
        .priority = .high,
        .status = .open,
    }};
    const store = LegacyStore{ .next_id = 2, .tasks = &tasks };
    const bytes = try memorypack.encode(allocator, store);
    defer allocator.free(bytes);
    try writeFile(io, path, bytes);
    std.debug.print("Wrote legacy schema store: {s}\n", .{path});
}

pub fn main(init: std.process.Init) !void {
    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.next() orelse return error.InvalidData;

    var store_path: []const u8 = "tasks.bin";
    var first = args.next() orelse return error.InvalidData;
    if (std.mem.eql(u8, first, "--store")) {
        store_path = args.next() orelse return error.MissingStorePath;
        first = args.next() orelse return error.MissingCommand;
    }

    const allocator = std.heap.page_allocator;
    if (std.mem.eql(u8, first, "legacy-write")) {
        if (args.next() != null) return error.UnknownOption;
        try writeLegacy(init.io, allocator, store_path);
    } else {
        try runCommand(init.io, allocator, store_path, first, &args);
    }
}
