const std = @import("std");
const ziggy_core_build = @import("ziggy-core");

//
// Builds the module an app's Linux shell imports. The shell is Zig that talks to GTK 3 and WebKitGTK 4.1 through their C
// headers, and to the core through ziggy.h.
//
pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

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

    const module = b.addModule("ziggy-shell-linux", .{
        .root_source_file = b.path("src/index.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const test_step = b.step("test", "Run the unit tests of the parts that do not need GTK");
    const test_module = b.createModule(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
    });
    const unit_test = b.addTest(.{ .root_module = test_module });
    test_step.dependOn(&b.addRunArtifact(unit_test).step);

    module.addImport("c", translate_c.createModule());
    module.addImport("ui-files", ziggy_core.module("ziggy-ui-files"));
    // The shell links the runtime libraries by their full file names, which is what a program built against the
    // development packages ends up needing at run time anyway. Nothing but the runtime libraries has to be installed.
    const runtime_libraries = [_][]const u8{
        "libglib-2.0.so.0",
        "libgobject-2.0.so.0",
        "libgio-2.0.so.0",
        "libgdk-3.so.0",
        "libgtk-3.so.0",
        "libjavascriptcoregtk-4.1.so.0",
        "libwebkit2gtk-4.1.so.0",
    };
    // Only a Linux target links the runtime libraries. The unit tests need none of them, and finding them on a host that is not
    // Linux fails the build: the macOS job of the Ziggy example workflow failed its "Run the Zig unit tests" step here with
    // "error: RuntimeLibraryMissing" from findRuntimeLibrary, because macOS has no libglib-2.0.so.0.
    if (target.result.os.tag == .linux) {
        for (runtime_libraries) |library| {
            module.addObjectFile(.{ .cwd_relative = try findRuntimeLibrary(b, library) });
        }
    }
}

//
// The directories a Linux system keeps its shared libraries in, checked in this order.
//
const library_directories = [_][]const u8{
    "/usr/lib/x86_64-linux-gnu",
    "/usr/lib/aarch64-linux-gnu",
    "/lib/x86_64-linux-gnu",
    "/lib/aarch64-linux-gnu",
    "/usr/lib64",
    "/usr/lib",
    "/lib64",
    "/lib",
};

//
// Finds an installed runtime library by its file name and returns its full path. Fails the build, saying which library is
// missing and where it looked, when it is in none of the usual directories.
//
fn findRuntimeLibrary(b: *std.Build, file_name: []const u8) ![]const u8 {
    for (library_directories) |directory| {
        const path = b.fmt("{s}/{s}", .{ directory, file_name });
        std.Io.Dir.cwd().access(b.graph.io, path, .{}) catch {
            continue;
        };
        return path;
    }
    std.debug.print("The runtime library {s} is not installed. Looked in:\n", .{file_name});
    for (library_directories) |directory| {
        std.debug.print("  {s}\n", .{directory});
    }
    return error.RuntimeLibraryMissing;
}


//
// For an app's build.zig to call: makes the module that holds the app's built page, to be imported by the app's shell code.
// See embedPage in ziggy-core's build.zig for what it does. The module's `files` is what the app gives AppConfig.ui_files.
//
pub fn embedPage(b: *std.Build, shell_module: *std.Build.Module, page_directory: []const u8) !*std.Build.Module {
    return try ziggy_core_build.embedPage(b, shell_module, "ziggy-shell-linux", page_directory);
}
