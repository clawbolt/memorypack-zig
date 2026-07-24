const std = @import("std");
const memorypack = @import("memorypack");
const core = @import("core");
const services = @import("services");

pub const RequestKind = enum(u8) {
    ping,
    register_device,
    get_device,
    list_devices,
    decommission_device,
    ingest,
    add_rule,
    query,
    alerts,
    audit_verify,
    stats,
    shutdown,
};

const Empty = struct {};
pub const Request = union(RequestKind) {
    ping: Auth,
    register_device: RegisterRequest,
    get_device: DeviceRequest,
    list_devices: DeviceListRequest,
    decommission_device: DeviceRequest,
    ingest: IngestRequest,
    add_rule: RuleRequest,
    query: QueryRequest,
    alerts: Auth,
    audit_verify: Auth,
    stats: Auth,
    shutdown: Auth,
};

pub const Auth = struct {
    token: memorypack.Str,
};
pub const RegisterRequest = struct {
    token: memorypack.Str,
    id: memorypack.Str,
    name: memorypack.Str,
    kind: services.DeviceKind,
};
pub const DeviceRequest = struct {
    token: memorypack.Str,
    id: memorypack.Str,
};
pub const DeviceListRequest = struct {
    token: memorypack.Str,
    offset: u32,
    limit: u32,
};
pub const IngestRequest = struct {
    token: memorypack.Str,
    device_id: memorypack.Str,
    metric: memorypack.Str,
    value: f64,
    timestamp: i64,
};
pub const RuleRequest = struct {
    token: memorypack.Str,
    id: memorypack.Str,
    device_id: memorypack.Str,
    metric: memorypack.Str,
    op: services.RuleOp,
    threshold: f64,
};
pub const QueryRequest = struct {
    token: memorypack.Str,
    device_id: memorypack.Str,
    metric: memorypack.Str,
    start: i64,
    end: i64,
    limit: u32,
};

pub const Response = struct {
    ok: bool,
    message: memorypack.Str,
    count: i64,
    value: memorypack.Str,
    items: []const memorypack.Str,
    intact: bool,
};

pub const Gateway = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    config: core.Config,
    iothub: services.IotHub,
    metrics: core.Metrics = .{},
    window_second: i64 = 0,
    token_calls: std.ArrayList(usize),
    stopping: bool = false,

    /// Creates the authenticated domain gateway.
    pub fn open(io: std.Io, allocator: std.mem.Allocator, config: core.Config) !Gateway {
        var gateway = Gateway{
            .allocator = allocator,
            .io = io,
            .config = config,
            .iothub = try services.IotHub.open(io, allocator, config.data_dir),
            .token_calls = .empty,
        };
        errdefer gateway.deinit();
        for (config.api_tokens) |_| try gateway.token_calls.append(allocator, 0);
        _ = try gateway.iothub.processAlerts(1000);
        return gateway;
    }

    /// Closes all iothub resources.
    pub fn deinit(self: *Gateway) void {
        self.token_calls.deinit(self.allocator);
        self.iothub.deinit();
    }

    /// Authenticates, rate-limits, and routes one request.
    pub fn handle(self: *Gateway, request: Request) !Response {
        const token = requestToken(request);
        const role = self.authorize(token) orelse {
            self.metrics.rejected_auth += 1;
            return self.failure("unauthorized");
        };
        if (!self.rateAllowed(token)) {
            self.metrics.rejected_rate += 1;
            return self.failure("rate limited");
        }
        self.metrics.requests += 1;
        return switch (request) {
            .ping => self.success("pong", 0),
            .register_device => |value| if (role == .viewer) self.failure("forbidden") else self.register(value),
            .get_device => |value| self.getDevice(value),
            .list_devices => |value| self.listDevices(value),
            .decommission_device => |value| if (role == .viewer) self.failure("forbidden") else self.decommission(value),
            .ingest => |value| self.ingest(value),
            .add_rule => |value| self.addRule(value),
            .query => |value| self.query(value),
            .alerts => self.listAlerts(),
            .audit_verify => self.verify(),
            .stats => self.stats(),
            .shutdown => blk: {
                self.stopping = true;
                break :blk self.success("shutdown", 0);
            },
        };
    }

    fn authorize(self: *Gateway, token: []const u8) ?core.Role {
        for (self.config.api_tokens) |configured| if (std.mem.eql(u8, configured.value, token)) return configured.role;
        return null;
    }

    fn rateAllowed(self: *Gateway, token: []const u8) bool {
        const now: i64 = @intCast(@divTrunc(std.Io.Clock.real.now(self.io).nanoseconds, 1_000_000_000));
        if (now != self.window_second) {
            self.window_second = now;
            for (self.token_calls.items) |*value| value.* = 0;
        }
        for (self.config.api_tokens, 0..) |configured, index| {
            if (!std.mem.eql(u8, configured.value, token)) continue;
            if (self.token_calls.items.len <= index) {
                self.token_calls.resize(self.allocator, index + 1) catch return false;
                self.token_calls.items[index] = 0;
            }
            if (self.token_calls.items[index] >= self.config.rate_limit) return false;
            self.token_calls.items[index] += 1;
            return true;
        }
        return false;
    }

    fn register(self: *Gateway, value: RegisterRequest) !Response {
        try self.iothub.registerDevice(.{ .id = value.id, .name = value.name, .kind = value.kind, .status = .active, .tags = &.{}, .registered_at = @intCast(@divTrunc(std.Io.Clock.real.now(self.io).nanoseconds, 1_000_000_000)) });
        return self.success("device registered", 1);
    }

    fn getDevice(self: *Gateway, value: DeviceRequest) !Response {
        var device = (try self.iothub.getDevice(value.id.bytes)) orelse return self.failure("device not found");
        defer services.freeDevice(self.allocator, &device);
        return self.deviceResponse(device, "device found");
    }

    fn listDevices(self: *Gateway, value: DeviceListRequest) !Response {
        const devices = try self.iothub.listDevices(value.offset, value.limit);
        defer services.freeDeviceList(self.allocator, devices);
        var items: std.ArrayList(memorypack.Str) = .empty;
        errdefer freeItems(self.allocator, items.items);
        for (devices) |device| {
            const text = try std.fmt.allocPrint(self.allocator, "{s} {s} {s} {s}", .{ device.id.bytes, device.name.bytes, @tagName(device.kind), @tagName(device.status) });
            try items.append(self.allocator, .{ .bytes = text });
        }
        return .{ .ok = true, .message = .{ .bytes = "devices" }, .count = @intCast(items.items.len), .value = .{ .bytes = "" }, .items = try items.toOwnedSlice(self.allocator), .intact = true };
    }

    fn decommission(self: *Gateway, value: DeviceRequest) !Response {
        if (!try self.iothub.decommissionDevice(value.id.bytes)) return self.failure("device not found");
        return self.success("device decommissioned", 1);
    }

    fn deviceResponse(self: *Gateway, device: services.Device, message: []const u8) !Response {
        const text = try std.fmt.allocPrint(self.allocator, "{s} {s} {s} {s}", .{ device.id.bytes, device.name.bytes, @tagName(device.kind), @tagName(device.status) });
        var items: std.ArrayList(memorypack.Str) = .empty;
        try items.append(self.allocator, .{ .bytes = text });
        return .{ .ok = true, .message = .{ .bytes = message }, .count = 1, .value = .{ .bytes = "" }, .items = try items.toOwnedSlice(self.allocator), .intact = true };
    }

    fn ingest(self: *Gateway, value: IngestRequest) !Response {
        try self.iothub.ingest(.{ .device_id = value.device_id, .metric = value.metric, .value = value.value, .timestamp = value.timestamp });
        _ = try self.iothub.processAlerts(100);
        return self.success("reading ingested", 1);
    }

    fn addRule(self: *Gateway, value: RuleRequest) !Response {
        try self.iothub.addRule(.{ .id = value.id, .device_id = value.device_id, .metric = value.metric, .op = value.op, .threshold = value.threshold });
        return self.success("rule added", 1);
    }

    fn query(self: *Gateway, value: QueryRequest) !Response {
        const readings = try self.iothub.queryReadings(value.device_id.bytes, value.metric.bytes, value.start, value.end, value.limit);
        defer {
            for (readings) |*reading| memorypack.deinit(services.Reading, self.allocator, reading);
            self.allocator.free(readings);
        }
        var items: std.ArrayList(memorypack.Str) = .empty;
        errdefer freeItems(self.allocator, items.items);
        for (readings) |reading| {
            const text = try std.fmt.allocPrint(self.allocator, "{s} {s} {d} {d}", .{ reading.device_id.bytes, reading.metric.bytes, reading.value, reading.timestamp });
            try items.append(self.allocator, .{ .bytes = text });
        }
        return .{ .ok = true, .message = .{ .bytes = "query complete" }, .count = @intCast(items.items.len), .value = .{ .bytes = "" }, .items = try items.toOwnedSlice(self.allocator), .intact = true };
    }

    fn listAlerts(self: *Gateway) !Response {
        const alerts = try self.iothub.alerts();
        defer {
            for (alerts) |*alert| memorypack.deinit(services.Alert, self.allocator, alert);
            self.allocator.free(alerts);
        }
        var items: std.ArrayList(memorypack.Str) = .empty;
        errdefer freeItems(self.allocator, items.items);
        for (alerts) |alert| {
            const text = try std.fmt.allocPrint(self.allocator, "{s} {s} {d}", .{ alert.rule_id.bytes, alert.metric.bytes, alert.value });
            try items.append(self.allocator, .{ .bytes = text });
        }
        return .{ .ok = true, .message = .{ .bytes = "alerts" }, .count = @intCast(items.items.len), .value = .{ .bytes = "" }, .items = try items.toOwnedSlice(self.allocator), .intact = true };
    }

    fn verify(self: *Gateway) !Response {
        const intact = try self.iothub.audit.verify();
        return .{ .ok = intact, .message = .{ .bytes = if (intact) "audit intact" else "audit tampering detected" }, .count = 0, .value = .{ .bytes = "" }, .items = &.{}, .intact = intact };
    }

    fn stats(self: *Gateway) !Response {
        const devices = try self.iothub.devices.stats();
        const readings = try self.iothub.readings.stats();
        const alerts = try self.iothub.alerts_store.stats();
        return self.success("stats", @intCast(devices.records + readings.records + alerts.records));
    }

    fn success(self: *Gateway, message: []const u8, count: i64) Response {
        _ = self;
        return .{ .ok = true, .message = .{ .bytes = message }, .count = count, .value = .{ .bytes = "" }, .items = &.{}, .intact = true };
    }

    fn failure(self: *Gateway, message: []const u8) Response {
        _ = self;
        return .{ .ok = false, .message = .{ .bytes = message }, .count = 0, .value = .{ .bytes = "" }, .items = &.{}, .intact = false };
    }
};

fn requestToken(request: Request) []const u8 {
    return switch (request) {
        .ping => |v| v.token.bytes,
        .register_device => |v| v.token.bytes,
        .get_device => |v| v.token.bytes,
        .list_devices => |v| v.token.bytes,
        .decommission_device => |v| v.token.bytes,
        .ingest => |v| v.token.bytes,
        .add_rule => |v| v.token.bytes,
        .query => |v| v.token.bytes,
        .alerts => |v| v.token.bytes,
        .audit_verify => |v| v.token.bytes,
        .stats => |v| v.token.bytes,
        .shutdown => |v| v.token.bytes,
    };
}

fn freeItems(allocator: std.mem.Allocator, items: []memorypack.Str) void {
    for (items) |item| allocator.free(item.bytes);
    allocator.free(items);
}

pub fn freeResponse(allocator: std.mem.Allocator, response: *Response) void {
    if (response.items.len > 0) freeItems(allocator, @constCast(response.items));
}

test "gateway rejects invalid auth and enforces rate limit" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    const dir = "zig-cache/iothub-gateway";
    std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    const tokens = [_]core.Token{.{ .value = "good", .role = .admin }};
    var gateway = try Gateway.open(io, allocator, .{ .data_dir = dir, .rate_limit = 1, .api_tokens = &tokens });
    defer gateway.deinit();
    const bad = try gateway.handle(.{ .ping = .{ .token = .{ .bytes = "bad" } } });
    try std.testing.expect(!bad.ok);
    const good = try gateway.handle(.{ .ping = .{ .token = .{ .bytes = "good" } } });
    try std.testing.expect(good.ok);
    const limited = try gateway.handle(.{ .ping = .{ .token = .{ .bytes = "good" } } });
    try std.testing.expect(!limited.ok);
}

test "gateway device registry role enforcement" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    const dir = "zig-cache/iothub-gateway-devices";
    std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    const tokens = [_]core.Token{
        .{ .value = "admin", .role = .admin },
        .{ .value = "viewer", .role = .viewer },
    };
    var gateway = try Gateway.open(io, allocator, .{ .data_dir = dir, .rate_limit = 20, .api_tokens = &tokens });
    defer gateway.deinit();
    const registered = try gateway.handle(.{ .register_device = .{ .token = .{ .bytes = "admin" }, .id = .{ .bytes = "d1" }, .name = .{ .bytes = "One" }, .kind = .sensor } });
    try std.testing.expect(registered.ok);
    var listed = try gateway.handle(.{ .list_devices = .{ .token = .{ .bytes = "viewer" }, .offset = 0, .limit = 10 } });
    defer freeResponse(allocator, &listed);
    try std.testing.expect(listed.ok);
    try std.testing.expectEqual(@as(i64, 1), listed.count);
    const forbidden = try gateway.handle(.{ .decommission_device = .{ .token = .{ .bytes = "viewer" }, .id = .{ .bytes = "d1" } } });
    try std.testing.expect(!forbidden.ok);
    const decommissioned = try gateway.handle(.{ .decommission_device = .{ .token = .{ .bytes = "admin" }, .id = .{ .bytes = "d1" } } });
    try std.testing.expect(decommissioned.ok);
    var found = try gateway.handle(.{ .get_device = .{ .token = .{ .bytes = "viewer" }, .id = .{ .bytes = "d1" } } });
    defer freeResponse(allocator, &found);
    try std.testing.expect(found.ok);
    try std.testing.expect(std.mem.endsWith(u8, found.items[0].bytes, "decommissioned"));
}
