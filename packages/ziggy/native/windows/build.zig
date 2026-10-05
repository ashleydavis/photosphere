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

    // The headers are translated for the -gnu ABI of the target's architecture, so that they come from the mingw headers Zig
    // bundles. With the -msvc target on a machine that has the Windows SDK, Zig would hand translate-c the SDK's own headers,
    // which its C front end cannot parse (MSVC extensions such as __ptr64 in basetsd.h). The two ABIs share the calling
    // convention and struct layout on Windows, so the declarations are the same, and the executable is still built and linked
    // for the -msvc target.
    var translate_query = target.query;
    translate_query.abi = .gnu;
    const translate_c = b.addTranslateC(.{
        .root_source_file = b.path("src/c.h"),
        .target = b.resolveTargetQuery(translate_query),
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
    // The WebView2 static loader reads the registry and writes event traces, which live in advapi32.
    module.linkSystemLibrary("advapi32", .{});
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
