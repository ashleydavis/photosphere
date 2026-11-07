const std = @import("std");

//
// Zig has no C library headers for Android. They come from the NDK, through the libc file the build is given with --libc, and the steps
// that read C headers without compiling (translate-c, the C preprocessor) are not given that file, so the include directories are read
// out of it here.
//

//
// Returns the include directories of the libc file the build was given (the include_dir and sys_include_dir lines). Stops the build
// with a message when there is no libc file.
//
pub fn libcIncludeDirectories(b: *std.Build) ![]const []const u8 {
    const libc_file_path = b.libc_file orelse {
        std.debug.print("An Android build needs the NDK's C library, as a libc file: pass --libc <file>.\n", .{});
        return error.LibcFileMissing;
    };
    const libc_file_text = try std.Io.Dir.cwd().readFileAlloc(b.graph.io, libc_file_path, b.allocator, .limited(64 * 1024));
    var directories: std.ArrayList([]const u8) = .empty;
    var libc_lines = std.mem.splitScalar(u8, libc_file_text, '\n');
    while (libc_lines.next()) |line| {
        for ([_][]const u8{ "include_dir=", "sys_include_dir=" }) |key| {
            if (std.mem.startsWith(u8, line, key) and line.len > key.len) {
                try directories.append(b.allocator, line[key.len..]);
            }
        }
    }
    return directories.items;
}

//
// Gives a translate-c step the C library's include directories when the target is Android or the build has a libc file (the Apple SDK's,
// see packages-zig/apple-sdk.zig), and does nothing for any other.
//
pub fn addLibcIncludes(b: *std.Build, translate_c: *std.Build.Step.TranslateC, target: std.Build.ResolvedTarget) !void {
    if (!target.result.abi.isAndroid() and b.libc_file == null) {
        return;
    }
    for (try libcIncludeDirectories(b)) |directory| {
        translate_c.addSystemIncludePath(.{
            .cwd_relative = directory,
        });
    }
    // Bionic's ioctl.h declares a second ioctl that takes an unsigned request, using clang overloading attributes translate-c reads as a
    // conflicting redeclaration. The header's own opt-out removes it.
    if (target.result.abi.isAndroid()) {
        translate_c.defineCMacro("BIONIC_IOCTL_NO_SIGNEDNESS_OVERLOAD", "1");
    }
}

//
// Gives a C preprocessor command (zig cc -E) the C library's include directories when the target is Android or the build has a libc file,
// and does nothing for any
// other target.
//
pub fn addLibcIncludesToCommand(b: *std.Build, command: *std.Build.Step.Run, target: std.Build.ResolvedTarget) !void {
    if (!target.result.abi.isAndroid() and b.libc_file == null) {
        return;
    }
    for (try libcIncludeDirectories(b)) |directory| {
        command.addArgs(&.{ "-isystem", directory });
    }
}

//
// Returns the directory of the C library's libraries for the target's API level (the crt_dir line of the libc file). It holds libc, libm,
// libdl and liblog, which Zig does not search by itself when it is given a libc file.
//
pub fn libcLibraryDirectory(b: *std.Build) ![]const u8 {
    const libc_file_path = b.libc_file orelse {
        std.debug.print("An Android build needs the NDK's C library, as a libc file: pass --libc <file>.\n", .{});
        return error.LibcFileMissing;
    };
    const libc_file_text = try std.Io.Dir.cwd().readFileAlloc(b.graph.io, libc_file_path, b.allocator, .limited(64 * 1024));
    var libc_lines = std.mem.splitScalar(u8, libc_file_text, '\n');
    while (libc_lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "crt_dir=") and line.len > "crt_dir=".len) {
            return line["crt_dir=".len..];
        }
    }
    std.debug.print("The libc file {s} has no crt_dir line.\n", .{libc_file_path});
    return error.LibcFileHasNoCrtDir;
}
