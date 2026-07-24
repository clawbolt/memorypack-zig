const std = @import("std");
const memorypack = @import("memorypack");

const EventTag = enum(u16) {
    opened = 0,
    deposited = 1,
    withdrew = 2,
};

const Opened = struct {
    owner: memorypack.Str,
};

const Deposited = struct {
    amount: i64,
};

const Withdrew = struct {
    amount: i64,
};

const Event = union(EventTag) {
    opened: Opened,
    deposited: Deposited,
    withdrew: Withdrew,
};

const State = struct {
    owner: ?[]u8 = null,
    balance: i64 = 0,
    event_count: usize = 0,

    fn deinit(self: *State, allocator: std.mem.Allocator) void {
        if (self.owner) |owner| allocator.free(owner);
        self.* = .{};
    }
};

const PayloadReader = struct {
    bytes: []const u8,
    pos: usize = 0,

    pub fn read(self: *PayloadReader, destination: []u8) !usize {
        if (self.pos == self.bytes.len) return 0;
        const count = @min(@min(destination.len, 2), self.bytes.len - self.pos);
        @memcpy(destination[0..count], self.bytes[self.pos..][0..count]);
        self.pos += count;
        return count;
    }
};

const PayloadSink = struct {
    list: *std.ArrayList(u8),
    allocator: std.mem.Allocator,

    pub fn writeAll(self: PayloadSink, bytes: []const u8) !void {
        try self.list.appendSlice(self.allocator, bytes);
    }
};

const max_frame_size = 1024 * 1024;

fn parseAmount(text: []const u8) !i64 {
    const amount = try std.fmt.parseInt(i64, text, 10);
    if (amount <= 0) return error.AmountMustBePositive;
    return amount;
}

fn readFile(io: std.Io, allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(64 * 1024 * 1024));
}

fn appendEvent(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    event: Event,
) !void {
    var payload: std.ArrayList(u8) = .empty;
    defer payload.deinit(allocator);
    try memorypack.encodeTo(allocator, event, PayloadSink{
        .list = &payload,
        .allocator = allocator,
    });
    if (payload.items.len > std.math.maxInt(u32)) return error.EventTooLarge;

    var file = try std.Io.Dir.cwd().createFile(io, path, .{ .truncate = false });
    defer file.close(io);
    const file_size = try file.stat(io);
    var file_buffer: [4096]u8 = undefined;
    var writer = file.writerStreaming(io, &file_buffer);
    try writer.seekTo(file_size.size);
    var length: [4]u8 = undefined;
    std.mem.writeInt(u32, &length, @intCast(payload.items.len), .little);
    try writer.interface.writeAll(&length);
    try writer.interface.writeAll(payload.items);
    try writer.interface.flush();
}

fn applyEvent(allocator: std.mem.Allocator, state: *State, event: Event) !void {
    switch (event) {
        .opened => |opened| {
            if (state.owner != null) return error.AccountAlreadyOpened;
            state.owner = try allocator.dupe(u8, opened.owner.bytes);
        },
        .deposited => |deposited| {
            if (state.owner == null) return error.AccountNotOpened;
            state.balance += deposited.amount;
        },
        .withdrew => |withdrew| {
            if (state.owner == null) return error.AccountNotOpened;
            if (withdrew.amount > state.balance) return error.InsufficientFunds;
            state.balance -= withdrew.amount;
        },
    }
    state.event_count += 1;
}

fn replay(io: std.Io, allocator: std.mem.Allocator, path: []const u8) !void {
    const bytes = readFile(io, allocator, path) catch |err| switch (err) {
        error.FileNotFound => {
            std.debug.print("No event log yet.\n", .{});
            return;
        },
        else => return err,
    };
    defer allocator.free(bytes);

    var state = State{};
    defer state.deinit(allocator);
    var position: usize = 0;
    while (position < bytes.len) {
        if (bytes.len - position < 4) {
            std.debug.print("Warning: ignoring truncated final frame header.\n", .{});
            break;
        }
        const frame_length = std.mem.readInt(u32, bytes[position..][0..4], .little);
        position += 4;
        if (frame_length > max_frame_size or frame_length > bytes.len - position) {
            std.debug.print("Warning: ignoring truncated final event frame.\n", .{});
            break;
        }
        const frame = bytes[position..][0..@intCast(frame_length)];
        position += frame.len;
        var source = PayloadReader{ .bytes = frame };
        var event = try memorypack.decodeFromReader(Event, allocator, &source);
        defer memorypack.deinit(Event, allocator, &event);
        try applyEvent(allocator, &state, event);
    }

    if (state.owner) |owner| {
        std.debug.print("owner={s}, balance={d}, events={d}\n", .{
            owner,
            state.balance,
            state.event_count,
        });
    } else {
        std.debug.print("account not opened, balance=0, events=0\n", .{});
    }
}

fn commandAppend(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    command: []const u8,
    value: []const u8,
) !void {
    var event: Event = undefined;
    if (std.mem.eql(u8, command, "open")) {
        event = .{ .opened = .{ .owner = .{ .bytes = value } } };
    } else if (std.mem.eql(u8, command, "deposit")) {
        event = .{ .deposited = .{ .amount = try parseAmount(value) } };
    } else if (std.mem.eql(u8, command, "withdraw")) {
        event = .{ .withdrew = .{ .amount = try parseAmount(value) } };
    } else {
        return error.UnknownCommand;
    }
    try appendEvent(io, allocator, path, event);
    std.debug.print("Appended {s} event.\n", .{command});
}

pub fn main(init: std.process.Init) !void {
    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.next() orelse return error.InvalidData;
    const path = args.next() orelse "events.bin";
    const command = args.next() orelse return error.MissingCommand;
    const allocator = std.heap.page_allocator;

    if (std.mem.eql(u8, command, "replay") or std.mem.eql(u8, command, "state")) {
        if (args.next() != null) return error.UnknownArgument;
        try replay(init.io, allocator, path);
        return;
    }

    const value = args.next() orelse return error.MissingValue;
    if (args.next() != null) return error.UnknownArgument;
    try commandAppend(init.io, allocator, path, command, value);
}
