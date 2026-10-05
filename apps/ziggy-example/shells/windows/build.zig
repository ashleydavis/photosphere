const std = @import("std");
const ziggy_shell_build = @import("ziggy-shell-windows");

//
// Builds the Ziggy example's Windows shell, installed to zig-out/ziggy-example/ziggy-example.exe. The executable is the whole
// app: the built page is embedded in it and WebView2's loader is linked into it. The page is expected in ../../dist (bun run
// bundle:ui) and the loader's static library in ../../webview2-sdk (the setup script), and the build fails when either is
// missing.
//
pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const test_hooks = b.option(bool, "test-hooks", "Build the test hooks into the app (never for a release)") orelse false;

    const sdk_architecture = switch (target.result.cpu.arch) {
        .x86_64 => "x64",
        .aarch64 => "arm64",
        else => return error.UnsupportedArchitecture,
    };
    const compile_only = b.option(bool, "compile-only", "Compile the shell without linking the WebView2 loader, to check it on a machine that cannot link") orelse false;
    const shell = if (compile_only) b.dependency("ziggy-shell-windows", .{
        .target = target,
        .optimize = optimize,
        .@"webview2-include" = b.path("../../webview2-sdk/include"),
    }) else b.dependency("ziggy-shell-windows", .{
        .target = target,
        .optimize = optimize,
        .@"webview2-include" = b.path("../../webview2-sdk/include"),
        .@"webview2-loader-library" = b.path(b.fmt("../../webview2-sdk/{s}/WebView2LoaderStatic.lib", .{sdk_architecture})),
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
    module.addImport("ui-files", try ziggy_shell_build.embedPage(b, shell.module("ziggy-shell-windows"), "../../dist"));
    module.linkLibrary(core.artifact("ziggy_example"));

    const executable = b.addExecutable(.{
        .name = "ziggy-example",
        .root_module = module,
    });
    executable.subsystem = .windows;

    // Compiles the shell without linking it, for a machine that cannot link a Windows executable. The link needs Microsoft's
    // toolchain because the SDK's static loader is built with it.
    const check_step = b.step("check", "Compile the shell for type errors without linking");
    check_step.dependOn(&b.addObject(.{
        .name = "ziggy-example-check",
        .root_module = module,
    }).step);
    b.getInstallStep().dependOn(&b.addInstallArtifact(executable, .{
        .dest_dir = .{ .override = .{ .custom = "ziggy-example" } },
        .pdb_dir = .disabled,
    }).step);
}
