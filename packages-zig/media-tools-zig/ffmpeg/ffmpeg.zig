const std = @import("std");
const zlib_ng = @import("../../serialization-zig/zlib-ng/zlib-ng.zig");
const imagemagick = @import("../imagemagick/imagemagick.zig");
const host_libc = @import("../../host-libc.zig");

//
// Builds FFmpeg from the unmodified source in vendor/ffmpeg as one static library: libavutil, libavcodec, libavformat, libavfilter,
// libswscale and libswresample, and the sources of the `ffmpeg` and `ffprobe` command line programs, whose `main` functions are
// renamed by compiler flags (`ffmpeg_main` and `ffprobe_main`) so the program can call them. The source files and the flags are the
// ones FFmpeg's own configure and make use for the target, kept in ffmpeg/config/<target>/ by ffmpeg/generate-config.sh together
// with the headers and component lists configure writes. A target without a directory there fails the build with the command that
// makes one.
//

//
// FFmpeg built for a target.
//
pub const IFfmpeg = struct {
    // The static library, holding the libraries and the command line programs.
    library: *std.Build.Step.Compile,

    // The directory of the generated headers of the target (it holds config.h).
    config_directory: std.Build.LazyPath,

    // The directory of FFmpeg's own headers (it holds libavutil/avutil.h).
    source_directory: std.Build.LazyPath,
};

//
// The name of the directory of the generated files for the target, which is the same as ImageMagick's. Fails for a target FFmpeg is
// not built for.
//
fn configPath(b: *std.Build, target: std.Build.ResolvedTarget) ![]const u8 {
    const name = try imagemagick.configName(b, target);
    return b.fmt("packages-zig/media-tools-zig/ffmpeg/config/{s}", .{name});
}

//
// The files generate-config.sh writes that the build reads or compiles.
//
const required_files = [_][]const u8{
    "config.h",
    "config_components.h",
    "lists.txt",
    "flags.txt",
    "fftools-flags.txt",
    "includes.txt",
};

//
// Why FFmpeg cannot be built for the target, or null when it can. The build offers its steps for every target, and a step for one
// that cannot be built fails with this reason.
//
pub fn unsupportedReason(b: *std.Build, target: std.Build.ResolvedTarget) ?[]const u8 {
    if (imagemagick.zlibUnsupportedReason(b, target)) |reason| {
        return b.fmt("FFmpeg is built over zlib-ng. {s}", .{reason});
    }
    const path = configPath(b, target) catch {
        return b.fmt("FFmpeg is not built for {s}-{s}-{s}.", .{ @tagName(target.result.cpu.arch), @tagName(target.result.os.tag), @tagName(target.result.abi) });
    };
    for (required_files) |name| {
        b.build_root.handle.access(b.graph.io, b.fmt("{s}/{s}", .{ path, name }), .{}) catch {
            return b.fmt("FFmpeg's generated files are not in {s} ({s} is missing). Make them with: packages-zig/media-tools-zig/ffmpeg/generate-config.sh {s}", .{ path, name, std.fs.path.basename(path) });
        };
    }
    return null;
}

//
// A line of lists.txt: a library or a program, and a path.
//
const IListEntry = struct {
    // The library (for example "libavcodec") or the program ("ffmpeg" or "ffprobe") the file belongs to.
    owner: []const u8,

    // The path under vendor/ffmpeg, with its extension for a library file and without for a program file.
    path: []const u8,
};

//
// Reads a file under the build root.
//
fn readBuildFile(b: *std.Build, path: []const u8) ![]const u8 {
    return try b.build_root.handle.readFileAlloc(b.graph.io, path, b.allocator, .limited(16 * 1024 * 1024));
}

//
// Reads lists.txt: a line for each source file of a library and of each program.
//
fn readList(b: *std.Build, path: []const u8) ![]const IListEntry {
    const text = try readBuildFile(b, path);
    var entries: std.ArrayList(IListEntry) = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) {
            continue;
        }
        const separator = std.mem.indexOfScalar(u8, line, ' ') orelse {
            std.log.err("A line of {s} has no space: {s}", .{ path, line });
            return error.BadList;
        };
        try entries.append(b.allocator, .{
            .owner = line[0..separator],
            .path = line[separator + 1 ..],
        });
    }
    return entries.items;
}

//
// Reads flags.txt: a flag a line.
//
fn readFlags(b: *std.Build, path: []const u8) ![]const []const u8 {
    const text = try readBuildFile(b, path);
    var flags: std.ArrayList([]const u8) = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (line.len > 0) {
            try flags.append(b.allocator, line);
        }
    }
    return flags.items;
}

//
// Whether the list already holds the path.
//
fn contains(list: []const []const u8, path: []const u8) bool {
    for (list) |existing| {
        if (std.mem.eql(u8, existing, path)) {
            return true;
        }
    }
    return false;
}

//
// Builds FFmpeg for the target over zlib (built once by zlib-ng.zig, so the program has one copy of it).
//
pub fn buildFfmpeg(b: *std.Build, target: std.Build.ResolvedTarget, zlib: zlib_ng.IZlibNg) !IFfmpeg {
    const config_path = try configPath(b, target);
    const entries = try readList(b, b.fmt("{s}/lists.txt", .{config_path}));
    // The library ends up in Android's shared library. FFmpeg's aarch64 assembly addresses its tables with relocations that a
    // shared library allows only for symbols that cannot be replaced by another library's, which FFmpeg's own shared build gets by
    // building with hidden visibility, and so does this.
    const hidden: []const []const u8 = if (target.result.abi.isAndroid()) &.{"-fvisibility=hidden"} else &.{};
    const library_flags = try joinFlags(b, try readFlags(b, b.fmt("{s}/flags.txt", .{config_path})), hidden);
    const tool_flags = try joinFlags(b, try readFlags(b, b.fmt("{s}/fftools-flags.txt", .{config_path})), hidden);
    const include_directories = try readFlags(b, b.fmt("{s}/includes.txt", .{config_path}));

    const library = b.addLibrary(.{
        .name = "ffmpeg",
        .linkage = .static,
        .root_module = b.createModule(.{
            .target = imagemagick.libraryTarget(b, target),
            .optimize = .ReleaseFast,
            .link_libc = true,
            .strip = true,
            // The library ends up in Android's shared library, whose code must not depend on where it is loaded.
            .pic = if (target.result.abi.isAndroid()) true else null,
        }),
    });
    const module = library.root_module;
    // The build and source directories, as configure's own flags give them (-I. -Isrc/).
    module.addIncludePath(b.path(config_path));
    module.addIncludePath(b.path("vendor/ffmpeg"));
    module.addIncludePath(zlib.include_directory);
    module.linkLibrary(zlib.library);
    // The directories configure adds for what the C library lacks.
    for (include_directories) |directory| {
        module.addIncludePath(b.path(b.fmt("vendor/ffmpeg/{s}", .{directory})));
    }

    // The sources of the command line programs that have a main function are built through ffmpeg-main.c and ffprobe-main.c, which rename
    // it, and ffprobe with the names that the two programs both define as their own renamed, since both are built into the same library.
    const ffprobe_main_flags = [_][]const u8{
        "-Dprogram_name=ffprobe_program_name",
        "-Dprogram_birth_year=ffprobe_program_birth_year",
        "-Dshow_help_default=ffprobe_show_help_default",
    };

    var library_files: std.ArrayList([]const u8) = .empty;
    var tool_files: std.ArrayList([]const u8) = .empty;
    var generated_files: std.ArrayList([]const u8) = .empty;
    for (entries) |entry| {
        const is_program = std.mem.eql(u8, entry.owner, "ffmpeg") or std.mem.eql(u8, entry.owner, "ffprobe");
        const source = if (is_program) b.fmt("{s}.c", .{entry.path}) else entry.path;
        // The two resources of the command line programs are written by make, so they are in the generated files.
        if (std.mem.startsWith(u8, source, "fftools/resources/graph.")) {
            if (!contains(generated_files.items, source)) {
                try generated_files.append(b.allocator, source);
            }
            continue;
        }
        // A program FFmpeg's own build runs on the build machine to write two of swscale's aarch64 sources, not part of the library (see
        // addSwscaleAarch64Ops).
        if (std.mem.eql(u8, source, "libswscale/aarch64/ops_asmgen.c")) {
            try addSwscaleAarch64Ops(b, module, library_flags);
            continue;
        }
        if (std.mem.eql(u8, source, "fftools/ffmpeg.c") or std.mem.eql(u8, source, "fftools/ffprobe.c")) {
            continue;
        }
        const files = if (is_program) &tool_files else &library_files;
        if (!contains(files.items, source)) {
            try files.append(b.allocator, source);
        }
    }

    module.addCSourceFiles(.{
        .root = b.path("vendor/ffmpeg"),
        .files = library_files.items,
        .flags = library_flags,
    });
    module.addCSourceFiles(.{
        .root = b.path("vendor/ffmpeg"),
        .files = tool_files.items,
        .flags = tool_flags,
    });
    module.addCSourceFiles(.{
        .root = b.path(config_path),
        .files = generated_files.items,
        .flags = tool_flags,
    });
    module.addCSourceFiles(.{
        .root = b.path("packages-zig/media-tools-zig/ffmpeg"),
        .files = &.{"ffmpeg-main.c"},
        .flags = tool_flags,
    });
    module.addCSourceFiles(.{
        .root = b.path("packages-zig/media-tools-zig/ffmpeg"),
        .files = &.{"ffprobe-main.c"},
        .flags = try joinFlags(b, tool_flags, &ffprobe_main_flags),
    });

    return .{
        .library = library,
        .config_directory = b.path(config_path),
        .source_directory = b.path("vendor/ffmpeg"),
    };
}

//
// Builds FFmpeg for the target and links it into the module.
//
pub fn addFfmpeg(b: *std.Build, module: *std.Build.Module, target: std.Build.ResolvedTarget, zlib: zlib_ng.IZlibNg) !void {
    if (unsupportedReason(b, target)) |reason| {
        std.log.err("{s}", .{reason});
        return error.UnsupportedTarget;
    }
    const ffmpeg = try buildFfmpeg(b, target, zlib);
    module.linkLibrary(ffmpeg.library);
}

//
// The flags followed by the extra flags.
//
fn joinFlags(b: *std.Build, flags: []const []const u8, extra: []const []const u8) ![]const []const u8 {
    var joined: std.ArrayList([]const u8) = .empty;
    try joined.appendSlice(b.allocator, flags);
    try joined.appendSlice(b.allocator, extra);
    return joined.items;
}

//
// Adds the two sources of swscale's aarch64 operations that FFmpeg's build writes with a program of its own
// (libswscale/aarch64/Makefile): ops_asmgen is built for the machine running the build and run with -ops for ops_neon.gen.S and with
// -lookup for ops_lookup.gen.c, which are compiled into the library like its other sources.
//
fn addSwscaleAarch64Ops(b: *std.Build, module: *std.Build.Module, flags: []const []const u8) !void {
    const generator = b.addExecutable(.{
        .name = "ffmpeg-ops-asmgen",
        .root_module = b.createModule(.{
            .target = b.graph.host,
            .optimize = .ReleaseFast,
            .link_libc = true,
        }),
    });
    generator.root_module.addIncludePath(b.path("vendor/ffmpeg"));
    generator.root_module.addCSourceFiles(.{
        .root = b.path("vendor/ffmpeg"),
        .files = &.{"libswscale/aarch64/ops_asmgen.c"},
        // The flags FFmpeg's make compiles its host programs with (HOSTCFLAGS).
        .flags = &.{ "-D_ISOC11_SOURCE", "-D_POSIX_C_SOURCE=200112", "-D_XOPEN_SOURCE=600", "-std=c17" },
    });
    host_libc.useHostLibc(b, generator);
    const write_ops = b.addRunArtifact(generator);
    write_ops.addArg("-ops");
    const write_lookup = b.addRunArtifact(generator);
    write_lookup.addArg("-lookup");
    module.addCSourceFile(.{
        .file = write_ops.captureStdOut(.{
            .basename = "ops_neon.gen.S",
        }),
        .flags = flags,
    });
    module.addCSourceFile(.{
        .file = write_lookup.captureStdOut(.{
            .basename = "ops_lookup.gen.c",
        }),
        .flags = flags,
    });
}
