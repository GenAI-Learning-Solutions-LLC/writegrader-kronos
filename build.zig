const std = @import("std");
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const exe = b.addExecutable(.{
        .name = "server",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .link_libc = true,
            .optimize = optimize,
        }),
    });
    exe.root_module.addIncludePath(b.path("src"));
    exe.root_module.addIncludePath(.{ .cwd_relative = "/usr/local/include" });
    exe.root_module.addLibraryPath(.{ .cwd_relative = "/usr/local/lib" });
    exe.root_module.addCSourceFile(.{ .file = b.path("src/dynamo.c"), .flags = &.{} });
    exe.root_module.linkSystemLibrary("curl", .{.use_pkg_config = .no});
    exe.root_module.linkSystemLibrary("sqlite3", .{.use_pkg_config = .no});
    b.installArtifact(exe);
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
}
