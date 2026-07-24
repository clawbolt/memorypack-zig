const std = @import("std");
const memorypack = @import("memorypack");
const core = @import("core");
const gateway = @import("gateway");
const services = @import("services");

const max_frame_size = 1024 * 1024;
const default_tokens = [_]core.Token{
    .{ .value = "admin-token", .role = .admin },
    .{ .value = "operator-token", .role = .operator },
    .{ .value = "viewer-token", .role = .viewer },
};

fn flag(args: *std.process.Args.Iterator, name: []const u8, fallback: []const u8) []const u8 {
    var copy = args.*;
    while (copy.next()) |value| {
        if (std.mem.eql(u8, value, name)) return copy.next() orelse fallback;
    }
    return fallback;
}

fn port(args: *std.process.Args.Iterator) !u16 {
    const text = flag(args, "--port", "39551");
    return std.fmt.parseInt(u16, text, 10);
}

fn frameWrite(writer: *std.Io.net.Stream.Writer, allocator: std.mem.Allocator, value: anytype) !void {
    return core.writeFrame(writer, allocator, max_frame_size, value);
}

fn frameRead(reader: *std.Io.net.Stream.Reader, allocator: std.mem.Allocator, comptime T: type) !T {
    return core.readFrame(reader, allocator, max_frame_size, T);
}

fn makeConfig(data_dir: []const u8) core.Config {
    return .{ .data_dir = data_dir, .api_port = 39551, .rate_limit = 20, .api_tokens = &default_tokens };
}

fn serve(init: std.process.Init, allocator: std.mem.Allocator, data_dir: []const u8, listen_port: u16) !void {
    var app = try gateway.Gateway.open(init.io, allocator, makeConfig(data_dir));
    defer app.deinit();
    const address: std.Io.net.IpAddress = .{ .ip4 = .loopback(listen_port) };
    var server = try address.listen(init.io, .{ .reuse_address = true });
    defer server.deinit(init.io);
    core.log(.info, "gateway", "iothub gateway listening");
    while (!app.stopping) {
        var stream = try server.accept(init.io);
        defer stream.close(init.io);
        var read_buffer: [4096]u8 = undefined;
        var write_buffer: [4096]u8 = undefined;
        var reader = stream.reader(init.io, &read_buffer);
        var writer = stream.writer(init.io, &write_buffer);
        while (!app.stopping) {
            var request = frameRead(&reader, allocator, gateway.Request) catch |err| switch (err) {
                error.EndOfStream => break,
                else => return err,
            };
            defer memorypack.deinit(gateway.Request, allocator, &request);
            var response = app.handle(request) catch |err| gateway.Response{ .ok = false, .message = .{ .bytes = @errorName(err) }, .count = 0, .value = .{ .bytes = "" }, .items = &.{}, .intact = false };
            defer gateway.freeResponse(allocator, &response);
            try frameWrite(&writer, allocator, response);
        }
    }
}

const Client = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    stream: std.Io.net.Stream,
    reader: std.Io.net.Stream.Reader,
    writer: std.Io.net.Stream.Writer,

    fn connect(init: std.process.Init, allocator: std.mem.Allocator, listen_port: u16) !Client {
        const address: std.Io.net.IpAddress = .{ .ip4 = .loopback(listen_port) };
        var stream = try address.connect(init.io, .{ .mode = .stream });
        const rb = try allocator.alloc(u8, 4096);
        errdefer allocator.free(rb);
        const wb = try allocator.alloc(u8, 4096);
        errdefer allocator.free(wb);
        return .{ .allocator = allocator, .io = init.io, .stream = stream, .reader = stream.reader(init.io, rb), .writer = stream.writer(init.io, wb) };
    }

    fn deinit(self: *Client) void {
        self.stream.close(self.io);
        self.allocator.free(self.reader.interface.buffer);
        self.allocator.free(self.writer.interface.buffer);
    }

    fn request(self: *Client, value: gateway.Request) !gateway.Response {
        try frameWrite(&self.writer, self.allocator, value);
        return frameRead(&self.reader, self.allocator, gateway.Response);
    }
};

fn auth(args: *std.process.Args.Iterator) memorypack.Str {
    return .{ .bytes = flag(args, "--token", "operator-token") };
}

fn client(init: std.process.Init, allocator: std.mem.Allocator, command: []const u8, args: *std.process.Args.Iterator) !void {
    var connection = try Client.connect(init, allocator, try port(args));
    defer connection.deinit();
    if (std.mem.eql(u8, command, "rate-test")) {
        var rejected: usize = 0;
        for (0..25) |_| {
            var response = try connection.request(.{ .ping = .{ .token = auth(args) } });
            defer memorypack.deinit(gateway.Response, allocator, &response);
            if (!response.ok) rejected += 1;
        }
        std.debug.print("rate-test: rejected={d}\n", .{rejected});
        if (rejected == 0) return error.RateLimitNotTriggered;
        return;
    }
    var request: gateway.Request = undefined;
    if (std.mem.eql(u8, command, "ping")) {
        request = .{ .ping = .{ .token = auth(args) } };
    } else if (std.mem.eql(u8, command, "register-device")) {
        request = .{ .register_device = .{ .token = auth(args), .id = .{ .bytes = flag(args, "--id", "device-1") }, .name = .{ .bytes = flag(args, "--name", "Sensor") }, .kind = .sensor } };
    } else if (std.mem.eql(u8, command, "get-device")) {
        request = .{ .get_device = .{ .token = auth(args), .id = .{ .bytes = flag(args, "--id", "device-1") } } };
    } else if (std.mem.eql(u8, command, "list-devices")) {
        request = .{ .list_devices = .{ .token = auth(args), .offset = try std.fmt.parseInt(u32, flag(args, "--offset", "0"), 10), .limit = try std.fmt.parseInt(u32, flag(args, "--limit", "100"), 10) } };
    } else if (std.mem.eql(u8, command, "decommission-device")) {
        request = .{ .decommission_device = .{ .token = auth(args), .id = .{ .bytes = flag(args, "--id", "device-1") } } };
    } else if (std.mem.eql(u8, command, "add-rule")) {
        request = .{ .add_rule = .{ .token = auth(args), .id = .{ .bytes = flag(args, "--id", "rule-1") }, .device_id = .{ .bytes = flag(args, "--device", "device-1") }, .metric = .{ .bytes = flag(args, "--metric", "temperature") }, .op = .gt, .threshold = try std.fmt.parseFloat(f64, flag(args, "--threshold", "20")) } };
    } else if (std.mem.eql(u8, command, "ingest")) {
        request = .{ .ingest = .{ .token = auth(args), .device_id = .{ .bytes = flag(args, "--device", "device-1") }, .metric = .{ .bytes = flag(args, "--metric", "temperature") }, .value = try std.fmt.parseFloat(f64, flag(args, "--value", "25")), .timestamp = try std.fmt.parseInt(i64, flag(args, "--timestamp", "1"), 10) } };
    } else if (std.mem.eql(u8, command, "query")) {
        request = .{ .query = .{ .token = auth(args), .device_id = .{ .bytes = flag(args, "--device", "device-1") }, .metric = .{ .bytes = flag(args, "--metric", "temperature") }, .start = try std.fmt.parseInt(i64, flag(args, "--start", "0"), 10), .end = try std.fmt.parseInt(i64, flag(args, "--end", "9999999999"), 10), .limit = try std.fmt.parseInt(u32, flag(args, "--limit", "100"), 10) } };
    } else if (std.mem.eql(u8, command, "alerts")) {
        request = .{ .alerts = .{ .token = auth(args) } };
    } else if (std.mem.eql(u8, command, "audit-verify")) {
        request = .{ .audit_verify = .{ .token = auth(args) } };
    } else if (std.mem.eql(u8, command, "stats")) {
        request = .{ .stats = .{ .token = auth(args) } };
    } else if (std.mem.eql(u8, command, "shutdown")) {
        request = .{ .shutdown = .{ .token = auth(args) } };
    } else return error.InvalidInput;
    var response = try connection.request(request);
    defer memorypack.deinit(gateway.Response, allocator, &response);
    std.debug.print("{s}: ok={} count={d} intact={} message={s}\n", .{ command, response.ok, response.count, response.intact, response.message.bytes });
    for (response.items) |item| std.debug.print("  {s}\n", .{item.bytes});
    if (!response.ok and !std.mem.eql(u8, command, "audit-verify")) return error.RequestFailed;
}

pub fn main(init: std.process.Init) !void {
    var args = try init.minimal.args.iterateAllocator(init.gpa);
    defer args.deinit();
    _ = args.next();
    const command = args.next() orelse return error.InvalidInput;
    if (std.mem.eql(u8, command, "serve")) {
        const data_dir = args.next() orelse return error.InvalidInput;
        return serve(init, init.gpa, data_dir, try port(&args));
    }
    return client(init, init.gpa, command, &args);
}
