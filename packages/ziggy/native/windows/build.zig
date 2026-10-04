const std = @import("std");

//
// Builds the module an app's Windows shell imports. The shell is Zig that talks to Win32 and to WebView2 through their C
// headers, and to the core through ziggy.h. The WebView2 headers come from the SDK the app's setup script downloads, whose
// include directory is passed in as the webview2-include option. WebView2Loader.dll is loaded at run time, so nothing
// links against the SDK.
//
pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const webview2_include = b.option(std.Build.LazyPath, "webview2-include", "The directory holding WebView2.h and EventToken.h");

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
    module.linkSystemLibrary("user32", .{});
    module.linkSystemLibrary("kernel32", .{});
    module.linkSystemLibrary("ole32", .{});
    module.linkSystemLibrary("shell32", .{});
    module.linkSystemLibrary("uuid", .{});
}
