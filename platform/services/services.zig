const std = @import("std");
const memorypack = @import("memorypack");
const storage = @import("storage");
const broker = @import("broker");
const audit = @import("audit");

pub const DeviceKind = enum(u8) { sensor, gateway, actuator };
pub const DeviceStatus = enum(u8) { active, decommissioned };
pub const Device = struct {
    pub const memorypack_version_tolerant = true;
    id: memorypack.Str,
    name: memorypack.Str,
    kind: DeviceKind,
    status: DeviceStatus,
    tags: []const memorypack.Str,
    registered_at: i64,
};
pub const Reading = struct {
    pub const memorypack_version_tolerant = true;
    device_id: memorypack.Str,
    metric: memorypack.Str,
    value: f64,
    timestamp: i64,
};
pub const RuleOp = enum(u8) { gt, lt, eq };
pub const Rule = struct {
    pub const memorypack_version_tolerant = true;
    id: memorypack.Str,
    device_id: memorypack.Str,
    metric: memorypack.Str,
    op: RuleOp,
    threshold: f64,
};
pub const Alert = struct {
    pub const memorypack_version_tolerant = true;
    id: i64,
    rule_id: memorypack.Str,
    device_id: memorypack.Str,
    metric: memorypack.Str,
    value: f64,
    timestamp: i64,
};

pub const Platform = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    devices: storage.Store,
    readings: storage.Store,
    rules_store: storage.Store,
    alerts_store: storage.Store,
    broker: broker.Broker,
    audit: audit.Store,
    rules: std.ArrayList(Rule),
    mutex: std.Io.Mutex = .init,
    closed: bool = false,

    /// Opens all platform domain stores under one data directory.
    pub fn open(io: std.Io, allocator: std.mem.Allocator, data_dir: []const u8) !Platform {
        const devices_dir = try std.fmt.allocPrint(allocator, "{s}/devices", .{data_dir});
        defer allocator.free(devices_dir);
        const readings_dir = try std.fmt.allocPrint(allocator, "{s}/readings", .{data_dir});
        defer allocator.free(readings_dir);
        const rules_dir = try std.fmt.allocPrint(allocator, "{s}/rules", .{data_dir});
        defer allocator.free(rules_dir);
        const alerts_dir = try std.fmt.allocPrint(allocator, "{s}/alerts", .{data_dir});
        defer allocator.free(alerts_dir);
        const broker_dir = try std.fmt.allocPrint(allocator, "{s}/broker", .{data_dir});
        defer allocator.free(broker_dir);
        const audit_dir = try std.fmt.allocPrint(allocator, "{s}/audit", .{data_dir});
        defer allocator.free(audit_dir);
        var platform = Platform{
            .allocator = allocator,
            .io = io,
            .devices = try storage.Store.open(io, allocator, .{ .data_dir = devices_dir }),
            .readings = undefined,
            .rules_store = undefined,
            .alerts_store = undefined,
            .broker = undefined,
            .audit = undefined,
            .rules = .empty,
        };
        errdefer platform.deinit();
        platform.readings = try storage.Store.open(io, allocator, .{ .data_dir = readings_dir });
        platform.rules_store = try storage.Store.open(io, allocator, .{ .data_dir = rules_dir });
        platform.alerts_store = try storage.Store.open(io, allocator, .{ .data_dir = alerts_dir });
        platform.broker = try broker.Broker.open(io, allocator, .{ .data_dir = broker_dir });
        platform.audit = try audit.Store.open(io, allocator, .{ .data_dir = audit_dir });
        const persisted_rules = try platform.rules_store.list();
        defer storage.freeRecordsForExample(allocator, persisted_rules);
        for (persisted_rules) |record| {
            const encoded = try hexDecode(allocator, record.value.bytes);
            defer allocator.free(encoded);
            const rule = try memorypack.decode(Rule, allocator, encoded);
            try platform.rules.append(allocator, rule);
        }
        return platform;
    }

    /// Closes every domain store.
    pub fn deinit(self: *Platform) void {
        self.mutex.lockUncancelable(self.io);
        if (self.closed) {
            self.mutex.unlock(self.io);
            return;
        }
        self.closed = true;
        for (self.rules.items) |*rule| deinitRule(self.allocator, rule);
        self.rules.deinit(self.allocator);
        self.mutex.unlock(self.io);
        self.audit.deinit();
        self.broker.deinit();
        self.alerts_store.deinit();
        self.rules_store.deinit();
        self.readings.deinit();
        self.devices.deinit();
    }

    /// Registers a device and records provisioning in the audit chain.
    pub fn registerDevice(self: *Platform, device: Device) !void {
        const bytes = try memorypack.encode(self.allocator, device);
        defer self.allocator.free(bytes);
        const encoded = try hexEncode(self.allocator, bytes);
        defer self.allocator.free(encoded);
        try self.devices.put(device.id.bytes, encoded);
        _ = try self.audit.append("operator", "device.register", device.id.bytes);
    }

    /// Adds a threshold rule for a device metric.
    pub fn addRule(self: *Platform, rule: Rule) !void {
        const bytes = try memorypack.encode(self.allocator, rule);
        defer self.allocator.free(bytes);
        const encoded = try hexEncode(self.allocator, bytes);
        defer self.allocator.free(encoded);
        try self.rules_store.put(rule.id.bytes, encoded);
        try self.rules.append(self.allocator, try cloneRule(self.allocator, rule));
        _ = try self.audit.append("operator", "rule.add", rule.id.bytes);
    }

    /// Persists a reading and publishes it to the alert topic.
    pub fn ingest(self: *Platform, reading: Reading) !void {
        const bytes = try memorypack.encode(self.allocator, reading);
        defer self.allocator.free(bytes);
        const encoded = try hexEncode(self.allocator, bytes);
        defer self.allocator.free(encoded);
        const key = try std.fmt.allocPrint(self.allocator, "{s}/{s}/{d}", .{ reading.device_id.bytes, reading.metric.bytes, reading.timestamp });
        defer self.allocator.free(key);
        try self.readings.put(key, encoded);
        _ = try self.broker.publish("telemetry", encoded);
    }

    /// Processes telemetry using at-least-once broker fetch/commit semantics.
    pub fn processAlerts(self: *Platform, max: usize) !usize {
        const events = try self.broker.fetch("telemetry", "alerting", max);
        defer {
            for (events) |*event| broker.deinitEvent(self.allocator, event);
            self.allocator.free(events);
        }
        var processed: usize = 0;
        for (events) |event| {
            const decoded = hexDecode(self.allocator, event.payload.bytes) catch continue;
            defer self.allocator.free(decoded);
            var reading = memorypack.decode(Reading, self.allocator, decoded) catch continue;
            defer memorypack.deinit(Reading, self.allocator, &reading);
            for (self.rules.items) |rule| {
                if (!std.mem.eql(u8, rule.device_id.bytes, reading.device_id.bytes) or !std.mem.eql(u8, rule.metric.bytes, reading.metric.bytes)) continue;
                const triggered = switch (rule.op) {
                    .gt => reading.value > rule.threshold,
                    .lt => reading.value < rule.threshold,
                    .eq => reading.value == rule.threshold,
                };
                if (!triggered) continue;
                const alert = Alert{ .id = event.offset, .rule_id = rule.id, .device_id = reading.device_id, .metric = reading.metric, .value = reading.value, .timestamp = reading.timestamp };
                const bytes = try memorypack.encode(self.allocator, alert);
                defer self.allocator.free(bytes);
                const encoded = try hexEncode(self.allocator, bytes);
                defer self.allocator.free(encoded);
                const key = try std.fmt.allocPrint(self.allocator, "{d}", .{alert.id});
                defer self.allocator.free(key);
                try self.alerts_store.put(key, encoded);
                _ = try self.audit.append("alerting", "alert.raise", rule.id.bytes);
            }
            processed += 1;
            try self.broker.commit("telemetry", "alerting", event.offset + 1);
        }
        return processed;
    }

    /// Queries persisted readings by device/metric/time range.
    pub fn queryReadings(self: *Platform, device: []const u8, metric: []const u8, start: i64, end: i64, limit: usize) ![]Reading {
        const records = try self.readings.list();
        defer storage.freeRecordsForExample(self.allocator, records);
        var result: std.ArrayList(Reading) = .empty;
        errdefer freeReadings(self.allocator, result.items);
        for (records) |record| {
            if (!std.mem.startsWith(u8, record.key.bytes, device) or !std.mem.containsAtLeast(u8, record.key.bytes, 1, metric)) continue;
            const decoded = hexDecode(self.allocator, record.value.bytes) catch continue;
            defer self.allocator.free(decoded);
            var reading = memorypack.decode(Reading, self.allocator, decoded) catch continue;
            if (reading.timestamp < start or reading.timestamp > end) {
                memorypack.deinit(Reading, self.allocator, &reading);
                continue;
            }
            try result.append(self.allocator, reading);
            if (result.items.len == limit) break;
        }
        return result.toOwnedSlice(self.allocator);
    }

    /// Lists active alerts stored by the alerting consumer.
    pub fn alerts(self: *Platform) ![]Alert {
        const records = try self.alerts_store.list();
        defer storage.freeRecordsForExample(self.allocator, records);
        var result: std.ArrayList(Alert) = .empty;
        errdefer freeAlerts(self.allocator, result.items);
        for (records) |record| {
            const decoded = try hexDecode(self.allocator, record.value.bytes);
            defer self.allocator.free(decoded);
            try result.append(self.allocator, try memorypack.decode(Alert, self.allocator, decoded));
        }
        return result.toOwnedSlice(self.allocator);
    }
};

fn cloneRule(allocator: std.mem.Allocator, rule: Rule) !Rule {
    return .{ .id = .{ .bytes = try allocator.dupe(u8, rule.id.bytes) }, .device_id = .{ .bytes = try allocator.dupe(u8, rule.device_id.bytes) }, .metric = .{ .bytes = try allocator.dupe(u8, rule.metric.bytes) }, .op = rule.op, .threshold = rule.threshold };
}
fn deinitRule(allocator: std.mem.Allocator, rule: *Rule) void {
    allocator.free(rule.id.bytes);
    allocator.free(rule.device_id.bytes);
    allocator.free(rule.metric.bytes);
}
fn freeReadings(allocator: std.mem.Allocator, values: []Reading) void {
    for (values) |*value| memorypack.deinit(Reading, allocator, value);
    allocator.free(values);
}
fn freeAlerts(allocator: std.mem.Allocator, values: []Alert) void {
    for (values) |*value| memorypack.deinit(Alert, allocator, value);
    allocator.free(values);
}

fn hexEncode(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    const result = try allocator.alloc(u8, bytes.len * 2);
    const alphabet = "0123456789abcdef";
    for (bytes, 0..) |byte, index| {
        result[index * 2] = alphabet[byte >> 4];
        result[index * 2 + 1] = alphabet[byte & 15];
    }
    return result;
}

fn hexDecode(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    if (text.len % 2 != 0) return error.InvalidData;
    const result = try allocator.alloc(u8, text.len / 2);
    errdefer allocator.free(result);
    for (0..result.len) |index| {
        result[index] = (try hexDigit(text[index * 2])) * 16 + try hexDigit(text[index * 2 + 1]);
    }
    return result;
}

fn hexDigit(value: u8) !u8 {
    return switch (value) {
        '0'...'9' => value - '0',
        'a'...'f' => value - 'a' + 10,
        'A'...'F' => value - 'A' + 10,
        else => error.InvalidData,
    };
}

test "services ingest and alert flow" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    const dir = "zig-cache/platform-services";
    std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    var platform = try Platform.open(io, allocator, dir);
    defer platform.deinit();
    try platform.registerDevice(.{ .id = .{ .bytes = "d1" }, .name = .{ .bytes = "Kitchen" }, .kind = .sensor, .status = .active, .tags = &.{}, .registered_at = 1 });
    try platform.addRule(.{ .id = .{ .bytes = "hot" }, .device_id = .{ .bytes = "d1" }, .metric = .{ .bytes = "temp" }, .op = .gt, .threshold = 20 });
    try platform.ingest(.{ .device_id = .{ .bytes = "d1" }, .metric = .{ .bytes = "temp" }, .value = 25, .timestamp = 1 });
    try std.testing.expectEqual(@as(usize, 1), try platform.processAlerts(10));
    const values = try platform.alerts();
    defer freeAlerts(allocator, values);
    try std.testing.expectEqual(@as(usize, 1), values.len);
}
