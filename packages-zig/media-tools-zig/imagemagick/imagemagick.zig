const std = @import("std");
const android_libc = @import("../../android-libc.zig");
const zlib_ng = @import("../../serialization-zig/zlib-ng/zlib-ng.zig");
const libjpeg = @import("../libjpeg/libjpeg.zig");
const libpng = @import("../libpng/libpng.zig");
const libwebp = @import("../libwebp/libwebp.zig");

//
// Builds ImageMagick from the unmodified source in vendor/imagemagick as one static library, the way its configure script and
// Makefile.am build a static library with modules off (--disable-shared): MagickCore with the coders and filters compiled into it,
// and MagickWand. The delegates are libjpeg, libpng and zlib, which are the ones the mobile builds had; everything else
// ImageMagick can use is off.
//
// configure writes MagickCore/magick-baseconfig.h and MagickCore/version.h for the target it is run for. They are made by
// imagemagick/generate-config.sh, which runs ImageMagick's own configure with Zig as the C compiler, and are kept in
// imagemagick/config/<target>/. A target without a directory there fails the build with the command that makes one.
//

//
// ImageMagick built for a target.
//
pub const IImageMagick = struct {
    // The static library, holding MagickCore, MagickWand, the coders and the filters.
    library: *std.Build.Step.Compile,

    // The directory of the generated headers of the target (it holds MagickCore/magick-baseconfig.h).
    config_directory: std.Build.LazyPath,

    // The directory of ImageMagick's own headers (it holds MagickWand/MagickWand.h).
    source_directory: std.Build.LazyPath,

    // The libraries ImageMagick is built over, which a program that links ImageMagick links too.
    libraries: []const *std.Build.Step.Compile,
};

//
// The macros configure puts in the compiler flags and in the pkg-config flags of the library (MAGICK_PCFLAGS), because they are
// answers to its options (--with-quantum-depth=16, --enable-hdri and the default channel mask depth) that the headers need and that
// magick-baseconfig.h does not hold. Whatever includes ImageMagick's headers is built with them.
//
const configuration_macros = [_]struct {
    name: []const u8,
    value: []const u8,
}{
    .{
        .name = "MAGICKCORE_HDRI_ENABLE",
        .value = "1",
    },
    .{
        .name = "MAGICKCORE_QUANTUM_DEPTH",
        .value = "16",
    },
    .{
        .name = "MAGICKCORE_CHANNEL_MASK_DEPTH",
        .value = "32",
    },
};

//
// The glibc version the libraries are compiled against on Linux with glibc, which is the version generate-config.sh (of ImageMagick
// and of FFmpeg) gives the compiler. The generated headers are answers about the C library headers of that version, and a target
// that is the machine itself would be compiled against whatever glibc the machine has, so the libraries are compiled for this
// version on any machine. The code runs where glibc is the same or newer.
//
pub const glibc_version: std.SemanticVersion = .{
    .major = 2,
    .minor = 35,
    .patch = 0,
};

//
// The target the libraries are compiled for: the target, with glibc's version set to glibc_version when it is Linux with glibc.
//
pub fn libraryTarget(b: *std.Build, target: std.Build.ResolvedTarget) std.Build.ResolvedTarget {
    if (target.result.os.tag != .linux or !target.result.abi.isGnu()) {
        return target;
    }
    return b.resolveTargetQuery(.{
        .cpu_arch = target.result.cpu.arch,
        .os_tag = .linux,
        .abi = target.result.abi,
        .glibc_version = glibc_version,
    });
}

//
// The name of the directory of the generated headers for the target, which is the target's name as Zig spells it: for example
// "x86_64-linux-gnu", "aarch64-linux-android", "x86_64-windows-gnu", "x86_64-windows-msvc", "aarch64-macos" or "aarch64-ios-simulator". Fails for a
// target ImageMagick is not built for.
//
pub fn configName(b: *std.Build, target: std.Build.ResolvedTarget) ![]const u8 {
    const result = target.result;
    const arch = @tagName(result.cpu.arch);
    switch (result.os.tag) {
        .linux => {
            if (result.abi.isAndroid()) {
                return b.fmt("{s}-linux-android", .{arch});
            }
            if (result.abi.isGnu()) {
                return b.fmt("{s}-linux-gnu", .{arch});
            }
        },
        .windows => {
            if (result.abi == .gnu) {
                return b.fmt("{s}-windows-gnu", .{arch});
            }
            // The Photosphere App's Windows shell links WebView2's static loader, which is built for the MSVC ABI, so the app and
            // every library in it are built for that ABI.
            if (result.abi == .msvc) {
                return b.fmt("{s}-windows-msvc", .{arch});
            }
        },
        .macos => {
            return b.fmt("{s}-macos", .{arch});
        },
        .ios => {
            if (result.abi == .simulator) {
                return b.fmt("{s}-ios-simulator", .{arch});
            }
            return b.fmt("{s}-ios", .{arch});
        },
        else => {},
    }
    std.log.err("ImageMagick is not built for {s}-{s}-{s}.", .{ arch, @tagName(result.os.tag), @tagName(result.abi) });
    return error.UnsupportedTarget;
}

//
// The .c files directly in the directory (relative to the build root), by name, except the ones named.
//
pub fn sourceFiles(b: *std.Build, directory: []const u8, excluded: []const []const u8) ![]const []const u8 {
    var dir = try b.build_root.handle.openDir(b.graph.io, directory, .{
        .iterate = true,
    });
    defer dir.close(b.graph.io);
    var names: std.ArrayList([]const u8) = .empty;
    var iterator = dir.iterate();
    entries: while (try iterator.next(b.graph.io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".c")) {
            continue;
        }
        for (excluded) |excluded_name| {
            if (std.mem.eql(u8, entry.name, excluded_name)) {
                continue :entries;
            }
        }
        try names.append(b.allocator, b.fmt("{s}/{s}", .{ directory, entry.name }));
    }
    std.mem.sort([]const u8, names.items, {}, lessThan);
    return names.items;
}

//
// Orders names by their bytes, so the order of the files does not depend on the directory listing.
//
fn lessThan(context: void, left: []const u8, right: []const u8) bool {
    _ = context;
    return std.mem.order(u8, left, right) == .lt;
}

//
// Builds ImageMagick for the target over zlib (built once by zlib-ng.zig, so the program has one copy of it).
//
pub fn buildImageMagick(b: *std.Build, target: std.Build.ResolvedTarget, zlib: zlib_ng.IZlibNg) !IImageMagick {
    const name = try configName(b, target);
    const config_path = b.fmt("packages-zig/media-tools-zig/imagemagick/config/{s}", .{name});
    b.build_root.handle.access(b.graph.io, b.fmt("{s}/MagickCore/magick-baseconfig.h", .{config_path}), .{}) catch {
        std.log.err(
            "ImageMagick's generated headers for {s} are not in {s}. Make them with: packages-zig/media-tools-zig/imagemagick/generate-config.sh {s}",
            .{ name, config_path, name },
        );
        return error.ConfigMissing;
    };

    // MagickCore/threshold-map.h, which a zero configuration build includes in threshold.c and which Makefile.am makes from
    // config/thresholds.xml. A program run on the machine doing the build makes it, because the build cannot count on sed.
    const threshold_tool = b.addExecutable(.{
        .name = "threshold-map-tool",
        .root_module = b.createModule(.{
            .root_source_file = b.path("packages-zig/media-tools-zig/imagemagick/threshold-map-tool.zig"),
            .target = b.graph.host,
            .optimize = .ReleaseSafe,
            .imports = &.{
                .{
                    .name = "threshold-map",
                    .module = b.createModule(.{
                        .root_source_file = b.path("packages-zig/media-tools-zig/src/lib/threshold-map.zig"),
                        .target = b.graph.host,
                    }),
                },
            },
        }),
    });
    const threshold_command = b.addRunArtifact(threshold_tool);
    threshold_command.addFileArg(b.path("vendor/imagemagick/config/thresholds.xml"));
    const threshold_map_header = threshold_command.addOutputFileArg("threshold-map.h");
    const generated = b.addWriteFiles();
    _ = generated.addCopyFile(threshold_map_header, "MagickCore/threshold-map.h");

    const library_target = libraryTarget(b, target);
    const jpeg = libjpeg.buildLibjpeg(b, library_target);
    const png = libpng.buildLibpng(b, library_target, zlib.include_directory);
    const webp = try libwebp.buildLibwebp(b, library_target);

    const library = b.addLibrary(.{
        .name = "magick",
        .linkage = .static,
        .root_module = b.createModule(.{
            .target = library_target,
            .optimize = .ReleaseFast,
            .link_libc = true,
            .strip = true,
            // The library ends up in Android's shared library, whose code must not depend on where it is loaded.
            .pic = if (target.result.abi.isAndroid()) true else null,
        }),
    });
    const module = library.root_module;
    // AM_CPPFLAGS: the build and source directories. The generated headers come first.
    module.addIncludePath(b.path(config_path));
    module.addIncludePath(b.path("vendor/imagemagick"));
    module.addIncludePath(generated.getDirectory());
    module.addConfigHeader(jpeg.config_header);
    module.addIncludePath(jpeg.include_directory);
    module.addIncludePath(png.include_directory);
    module.addIncludePath(webp.include_directory);
    module.addIncludePath(zlib.include_directory);
    module.linkLibrary(jpeg.library);
    module.linkLibrary(png.library);
    module.linkLibrary(webp.library);
    module.linkLibrary(zlib.library);

    const is_windows = target.result.os.tag == .windows;
    var flags: std.ArrayList([]const u8) = .empty;
    for (configuration_macros) |macro| {
        try flags.append(b.allocator, b.fmt("-D{s}={s}", .{ macro.name, macro.value }));
    }
    try flags.append(b.allocator, "-O2");
    if (is_windows) {
        // configure adds -D_LIB to the preprocessor flags of a static build with MinGW, and -D_MT for a threaded one.
        try flags.append(b.allocator, "-D_LIB");
        try flags.append(b.allocator, "-D_MT");
    }

    // MAGICKCORE_BASE_SRCS: every .c file of MagickCore but vms.c, which is for VMS, and MAGICKCORE_PLATFORM_SRCS: nt-base.c and
    // nt-feature.c for Windows.
    const windows_only = [_][]const u8{ "nt-base.c", "nt-feature.c" };
    var core_excluded: std.ArrayList([]const u8) = .empty;
    try core_excluded.append(b.allocator, "vms.c");
    if (!is_windows) {
        try core_excluded.appendSlice(b.allocator, &windows_only);
    }
    // MAGICKCORE_CODER_SRCS, MAGICKCORE_FILTER_SRCS and the sources of MagickWand.
    const directories = [_]struct {
        path: []const u8,
        excluded: []const []const u8,
    }{
        .{
            .path = "vendor/imagemagick/MagickCore",
            .excluded = core_excluded.items,
        },
        .{
            .path = "vendor/imagemagick/MagickWand",
            .excluded = &.{},
        },
        .{
            .path = "vendor/imagemagick/coders",
            .excluded = &.{},
        },
        .{
            .path = "vendor/imagemagick/filters",
            .excluded = &.{},
        },
    };
    for (directories) |directory| {
        module.addCSourceFiles(.{
            .root = b.path("."),
            .files = try sourceFiles(b, directory.path, directory.excluded),
            .flags = flags.items,
        });
    }

    return .{
        .library = library,
        .config_directory = b.path(config_path),
        .source_directory = b.path("vendor/imagemagick"),
        .libraries = &.{ jpeg.library, png.library, webp.library, zlib.library },
    };
}

//
// The name the module translated from MagickWand.h is imported under.
//
pub const module_name = "magick";

//
// Builds ImageMagick for the target, links it into the module and adds the "magick" module translated from MagickWand.h.
//
pub fn addImageMagick(b: *std.Build, module: *std.Build.Module, target: std.Build.ResolvedTarget, zlib: zlib_ng.IZlibNg) !void {
    const imagemagick = try buildImageMagick(b, target, zlib);
    const translate_c = b.addTranslateC(.{
        .root_source_file = imagemagick.source_directory.path(b, "MagickWand/MagickWand.h"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    translate_c.addIncludePath(imagemagick.config_directory);
    translate_c.addIncludePath(imagemagick.source_directory);
    for (configuration_macros) |macro| {
        translate_c.defineCMacro(macro.name, macro.value);
    }
    try android_libc.addLibcIncludes(b, translate_c, target);
    module.addImport(module_name, translate_c.createModule());
    module.linkLibrary(imagemagick.library);
}

//
// Why zlib-ng, the zlib the program has one copy of, cannot be built for the target, or null when it can. Its build covers Linux (and
// Android), Windows, macOS and iOS, on x86_64 and aarch64.
//
pub fn zlibUnsupportedReason(b: *std.Build, target: std.Build.ResolvedTarget) ?[]const u8 {
    const os = target.result.os.tag;
    const arch = target.result.cpu.arch;
    // Zig ships no headers or libraries for iOS. On a Mac it finds the SDK of Xcode by itself, as the core library's own iOS build relies
    // on; anywhere else there is none to find.
    if (os == .ios and b.graph.host.result.os.tag != .macos) {
        return "Building for iOS needs Apple's iOS SDK, which comes with Xcode and only a Mac has. Build this on a Mac with Xcode installed.";
    }
    if (os != .linux and os != .windows and os != .macos and os != .ios) {
        return b.fmt("zlib-ng's build covers Linux, Android, Windows, macOS and iOS, not {s}.", .{@tagName(os)});
    }
    if (arch != .x86_64 and arch != .aarch64) {
        return b.fmt("zlib-ng's build covers x86_64 and aarch64, not {s}.", .{@tagName(arch)});
    }
    return null;
}

//
// Why ImageMagick cannot be built for the target, or null when it can. The build offers its steps for every target, and a step for
// one that cannot be built fails with this reason.
//
pub fn unsupportedReason(b: *std.Build, target: std.Build.ResolvedTarget) ?[]const u8 {
    if (zlibUnsupportedReason(b, target)) |reason| {
        return b.fmt("ImageMagick is built over zlib-ng. {s}", .{reason});
    }
    const name = configName(b, target) catch {
        return b.fmt("ImageMagick is not built for {s}-{s}-{s}.", .{ @tagName(target.result.cpu.arch), @tagName(target.result.os.tag), @tagName(target.result.abi) });
    };
    const config_path = b.fmt("packages-zig/media-tools-zig/imagemagick/config/{s}", .{name});
    b.build_root.handle.access(b.graph.io, b.fmt("{s}/MagickCore/magick-baseconfig.h", .{config_path}), .{}) catch {
        return b.fmt("ImageMagick's generated headers for {s} are not in {s}. Make them with: packages-zig/media-tools-zig/imagemagick/generate-config.sh {s}", .{ name, config_path, name });
    };
    return null;
}
