const std = @import("std");

//
// Builds the Ziggy example's Windows shell. Everything the app needs at run time is installed into one directory,
// zig-out/ziggy-example: the executable, WebView2Loader.dll beside it and the built page in the directory ui. The page is
// expected in ../../dist (bun run bundle:ui) and the loader in ../../webview2-sdk (the setup script), and the build fails
// when either is missing.
//
pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const test_hooks = b.option(bool, "test-hooks", "Build the test hooks into the app (never for a release)") orelse false;

    const shell = b.dependency("ziggy-shell-windows", .{
        .target = target,
        .optimize = optimize,
        .@"webview2-include" = b.path("../../webview2-sdk/include"),
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
    module.addImport("ziggy-shell-windows", shell.module("ziggy-shell-windows"));
    module.addAnonymousImport("ziggy-inject", .{
        .root_source_file = b.path("../../../../packages/ziggy-bridge/inject/ziggy-inject.js"),
    });
    module.linkLibrary(core.artifact("ziggy_example"));

    const executable = b.addExecutable(.{
        .name = "ziggy-example",
        .root_module = module,
    });
    executable.subsystem = .windows;
    const app_directory: std.Build.InstallDir = .{ .custom = "ziggy-example" };
    b.getInstallStep().dependOn(&b.addInstallArtifact(executable, .{
        .dest_dir = .{ .override = app_directory },
        .pdb_dir = .disabled,
    }).step);

    const loader_directory = switch (target.result.cpu.arch) {
        .x86_64 => "x64",
        .aarch64 => "arm64",
        else => return error.UnsupportedArchitecture,
    };
    const loader_path = b.fmt("../../webview2-sdk/{s}/WebView2Loader.dll", .{loader_directory});
    b.getInstallStep().dependOn(&b.addInstallFileWithDir(b.path(loader_path), app_directory, "WebView2Loader.dll").step);
    b.installDirectory(.{
        .source_dir = b.path("../../dist"),
        .install_dir = app_directory,
        .install_subdir = "ui",
    });
}
