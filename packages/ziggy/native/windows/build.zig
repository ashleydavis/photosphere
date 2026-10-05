const std = @import("std");
const ziggy_core_build = @import("ziggy-core");

//
// Builds the module an app's Windows shell imports. The shell is Zig that talks to Win32 and to WebView2 through their C
// headers, and to the core through ziggy.h. The WebView2 headers and the loader's static library come from the SDK the app's
// setup script downloads: the include directory is passed in as the webview2-include option and the library as the
// webview2-loader-library option. The loader is linked into the executable, so nothing is loaded from a file at run time.
//
pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const webview2_include = b.option(std.Build.LazyPath, "webview2-include", "The directory holding WebView2.h and EventToken.h");
    const webview2_loader_library = b.option(std.Build.LazyPath, "webview2-loader-library", "The SDK's WebView2LoaderStatic.lib for the target, which is linked into the executable");

    const host_test_module = b.createModule(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = b.graph.host,
        .optimize = optimize,
    });
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = host_test_module })).step);

    const include = webview2_include orelse {
        // Without the option the module cannot be built, but the unit tests above need none of it.
        return;
    };

    const ziggy_core = b.dependency("ziggy-core", .{
        .target = target,
        .optimize = optimize,
    });

    const translate_c = b.addTranslateC(.{
        .root_source_file = b.path("src/c.h"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    translate_c.addIncludePath(ziggy_core.path("src/lib"));
    translate_c.addIncludePath(include);

    const module = b.addModule("ziggy-shell-windows", .{
        .root_source_file = b.path("src/index.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    module.addImport("c", translate_c.createModule());
    module.addImport("ui-files", ziggy_core.module("ziggy-ui-files"));
    module.linkSystemLibrary("user32", .{});
    module.linkSystemLibrary("kernel32", .{});
    module.linkSystemLibrary("ole32", .{});
    module.linkSystemLibrary("shell32", .{});
    module.linkSystemLibrary("uuid", .{});
    // Without the library the module still compiles, which is how a machine that cannot link a Windows executable checks the
    // shell, but nothing built from it links.
    if (webview2_loader_library) |library| {
        module.addObjectFile(library);
    }
}

//
// For an app's build.zig to call: makes the module that holds the app's built page, to be imported by the app's shell code.
// See embedPage in ziggy-core's build.zig for what it does. The module's `files` is what the app gives AppConfig.ui_files.
//
pub fn embedPage(b: *std.Build, shell_module: *std.Build.Module, page_directory: []const u8) !*std.Build.Module {
    return try ziggy_core_build.embedPage(b, shell_module, "ziggy-shell-windows", page_directory);
}
