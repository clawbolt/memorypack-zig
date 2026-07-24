const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const module = b.addModule("memorypack", .{
        .root_source_file = b.path("src/memorypack.zig"),
        .target = target,
        .optimize = optimize,
    });

    const demo = b.addExecutable(.{
        .name = "memorypack-demo",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "memorypack", .module = module }},
        }),
    });
    b.installArtifact(demo);

    const run = b.addRunArtifact(demo);
    if (b.args) |args| run.addArgs(args);
    b.step("run", "Run the round-trip demo").dependOn(&run.step);

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/memorypack.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const test_step = b.step("test", "Run memorypack tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);

    const bench = b.addExecutable(.{
        .name = "memorypack-bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/bench.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "memorypack", .module = module }},
        }),
    });
    const run_bench = b.addRunArtifact(bench);
    b.step("bench", "Run MemoryPack and JSON benchmarks").dependOn(&run_bench.step);

    const player_profile = b.addExecutable(.{
        .name = "player-profile",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/player-profile/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "memorypack", .module = module }},
        }),
    });
    const run_player_profile = b.addRunArtifact(player_profile);
    if (b.args) |args| run_player_profile.addArgs(args);
    b.step("example", "Run the player profile interop example").dependOn(&run_player_profile.step);

    const rpc_client = b.addExecutable(.{
        .name = "rpc-client",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/rpc-socket/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "memorypack", .module = module }},
        }),
    });
    const run_rpc_client = b.addRunArtifact(rpc_client);
    if (b.args) |args| run_rpc_client.addArgs(args);
    b.step("rpc-client", "Run the Zig RPC socket client").dependOn(&run_rpc_client.step);

    const task_cli = b.addExecutable(.{
        .name = "task-cli",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/task-cli/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "memorypack", .module = module }},
        }),
    });
    const run_task_cli = b.addRunArtifact(task_cli);
    if (b.args) |args| run_task_cli.addArgs(args);
    b.step("task-cli", "Run the pure-Zig MemoryPack task CLI").dependOn(&run_task_cli.step);

    const event_log = b.addExecutable(.{
        .name = "event-log",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/event-log/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "memorypack", .module = module }},
        }),
    });
    const run_event_log = b.addRunArtifact(event_log);
    if (b.args) |args| run_event_log.addArgs(args);
    b.step("event-log", "Run the pure-Zig append-only event log").dependOn(&run_event_log.step);

    const zdb_module = b.addModule("zdb", .{
        .root_source_file = b.path("examples/zdb/zdb.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "memorypack", .module = module }},
    });
    const zdb_cli = b.addExecutable(.{
        .name = "zdb",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/zdb/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "memorypack", .module = module },
                .{ .name = "zdb", .module = zdb_module },
            },
        }),
    });
    const run_zdb = b.addRunArtifact(zdb_cli);
    if (b.args) |args| run_zdb.addArgs(args);
    b.step("zdb", "Run the pure-Zig embedded document database").dependOn(&run_zdb.step);

    const zdb_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/zdb/zdb.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "memorypack", .module = module }},
        }),
    });
    test_step.dependOn(&b.addRunArtifact(zdb_tests).step);

    const mq_module = b.addModule("mq", .{
        .root_source_file = b.path("examples/mq/mq.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "memorypack", .module = module }},
    });
    const mq_cli = b.addExecutable(.{
        .name = "mq",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/mq/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "memorypack", .module = module },
                .{ .name = "mq", .module = mq_module },
            },
        }),
    });
    const run_mq = b.addRunArtifact(mq_cli);
    if (b.args) |args| run_mq.addArgs(args);
    b.step("mq", "Run the pure-Zig durable message broker").dependOn(&run_mq.step);

    const mq_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/mq/mq.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "memorypack", .module = module }},
        }),
    });
    test_step.dependOn(&b.addRunArtifact(mq_tests).step);

    const audit_module = b.addModule("audit", .{
        .root_source_file = b.path("examples/audit/audit.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "memorypack", .module = module }},
    });
    const audit_cli = b.addExecutable(.{
        .name = "audit",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/audit/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "memorypack", .module = module },
                .{ .name = "audit", .module = audit_module },
            },
        }),
    });
    const run_audit = b.addRunArtifact(audit_cli);
    if (b.args) |args| run_audit.addArgs(args);
    b.step("audit", "Run the tamper-evident audit log").dependOn(&run_audit.step);

    const audit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/audit/audit.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "memorypack", .module = module }},
        }),
    });
    test_step.dependOn(&b.addRunArtifact(audit_tests).step);

    const iothub_core = b.addModule("iothub-core", .{
        .root_source_file = b.path("iothub/core/core.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "memorypack", .module = module }},
    });
    const iothub_storage = b.addModule("iothub-storage", .{
        .root_source_file = b.path("iothub/storage/storage.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "memorypack", .module = module },
            .{ .name = "core", .module = iothub_core },
        },
    });
    const iothub_core_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("iothub/core/core.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "memorypack", .module = module }},
        }),
    });
    test_step.dependOn(&b.addRunArtifact(iothub_core_tests).step);
    const iothub_storage_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("iothub/storage/storage.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "memorypack", .module = module },
                .{ .name = "core", .module = iothub_core },
            },
        }),
    });
    test_step.dependOn(&b.addRunArtifact(iothub_storage_tests).step);

    const iothub_broker = b.addModule("iothub-broker", .{
        .root_source_file = b.path("iothub/broker/broker.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "memorypack", .module = module },
            .{ .name = "core", .module = iothub_core },
        },
    });
    const iothub_audit = b.addModule("iothub-audit", .{
        .root_source_file = b.path("iothub/audit/audit.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "memorypack", .module = module }},
    });
    const iothub_services = b.addModule("iothub-services", .{
        .root_source_file = b.path("iothub/services/services.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "memorypack", .module = module },
            .{ .name = "storage", .module = iothub_storage },
            .{ .name = "broker", .module = iothub_broker },
            .{ .name = "audit", .module = iothub_audit },
        },
    });
    const iothub_broker_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("iothub/broker/broker.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "memorypack", .module = module },
                .{ .name = "core", .module = iothub_core },
            },
        }),
    });
    test_step.dependOn(&b.addRunArtifact(iothub_broker_tests).step);
    const iothub_audit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("iothub/audit/audit.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "memorypack", .module = module }},
        }),
    });
    test_step.dependOn(&b.addRunArtifact(iothub_audit_tests).step);
    const iothub_services_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("iothub/services/services.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "memorypack", .module = module },
                .{ .name = "storage", .module = iothub_storage },
                .{ .name = "broker", .module = iothub_broker },
                .{ .name = "audit", .module = iothub_audit },
            },
        }),
    });
    test_step.dependOn(&b.addRunArtifact(iothub_services_tests).step);

    const iothub_gateway = b.addModule("iothub-gateway", .{
        .root_source_file = b.path("iothub/gateway/gateway.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "memorypack", .module = module },
            .{ .name = "core", .module = iothub_core },
            .{ .name = "services", .module = iothub_services },
        },
    });
    const iothub_cli = b.addExecutable(.{
        .name = "iothub",
        .root_module = b.createModule(.{
            .root_source_file = b.path("iothub/cli/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "memorypack", .module = module },
                .{ .name = "core", .module = iothub_core },
                .{ .name = "gateway", .module = iothub_gateway },
                .{ .name = "services", .module = iothub_services },
            },
        }),
    });
    const run_iothub = b.addRunArtifact(iothub_cli);
    if (b.args) |args| run_iothub.addArgs(args);
    b.step("iothub", "Run the IoT Hub telemetry service").dependOn(&run_iothub.step);
    const iothub_gateway_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("iothub/gateway/gateway.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "memorypack", .module = module },
                .{ .name = "core", .module = iothub_core },
                .{ .name = "services", .module = iothub_services },
            },
        }),
    });
    test_step.dependOn(&b.addRunArtifact(iothub_gateway_tests).step);
    const iothub_e2e = b.addSystemCommand(&.{ "sh", "iothub/e2e/run.sh" });
    if (b.args) |args| iothub_e2e.addArgs(args);
    b.step("iothub-e2e", "Run the IoT Hub end-to-end flow").dependOn(&iothub_e2e.step);
}
