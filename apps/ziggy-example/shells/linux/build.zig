const std = @import("std");

//
// Builds the Ziggy example's Linux shell, installed to zig-out/bin/ziggy-example. The built page is expected in
// zig-out/bin/ui, put there by the sync script.
//
pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const test_hooks = b.option(bool, "test-hooks", "Build the test hooks into the app (never for a release)") orelse false;

    const shell = b.dependency("ziggy-shell-linux", .{
        .target = target,
        .optimize = optimize,
    });
    const core = b.dependency("ziggy-example-core", .{
        .target = target,
        .optimize = optimize,
        .@"test-hooks" = test_hooks,
    });

    const module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    module.addImport("ziggy-shell-linux", shell.module("ziggy-shell-linux"));
    module.addAnonymousImport("ziggy-inject", .{
        .root_source_file = b.path("../../../../packages/ziggy/bridge/inject/ziggy-inject.js"),
    });
    module.linkLibrary(core.artifact("ziggy_example"));

    const executable = b.addExecutable(.{
        .name = "ziggy-example",
        .root_module = module,
    });
    b.installArtifact(executable);
}
