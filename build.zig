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
}
