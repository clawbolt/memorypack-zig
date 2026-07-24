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
}
