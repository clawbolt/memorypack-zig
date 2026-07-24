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
    b.step("test", "Run memorypack tests").dependOn(&b.addRunArtifact(tests).step);

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
}
