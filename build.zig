const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mp4 = b.addModule("mp4", .{
        .root_source_file = b.path("src/mp4/mp4.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{},
    });

    const mod = b.addModule("media-formats", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "mp4", .module = mp4 },
        },
    });

    {
        const mp4_tests = b.addTest(.{ .root_module = mp4 });
        const run_mp4_tests = b.addRunArtifact(mp4_tests);

        const test_step = b.step("test", "Run tests");
        test_step.dependOn(&run_mp4_tests.step);
    }
}
