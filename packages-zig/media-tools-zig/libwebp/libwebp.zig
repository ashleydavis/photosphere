const std = @import("std");
const imagemagick = @import("../imagemagick/imagemagick.zig");

//
// Builds libwebp from the unmodified source in vendor/libwebp as a static library: the decoder, the encoder, their shared code
// and the sharpyuv library the encoder uses, the same directories its CMakeLists.txt builds into libwebp, with no flags for a
// particular processor. The code for SSE4.1, AVX2 and the like is in files that compile to nothing unless the compiler turns the
// feature on, so every target builds the same files and runs the code its baseline processor has (SSE2 on x86_64, NEON on arm64).
// The pieces for animated pictures (libwebpmux and libwebpdemux) are not built, so ImageMagick reads and writes single pictures.
//

//
// libwebp built for a target.
//
pub const ILibwebp = struct {
    // The static library.
    library: *std.Build.Step.Compile,

    // The directory that holds webp/decode.h, webp/encode.h and the rest of the library's headers, for the C code that includes them.
    include_directory: std.Build.LazyPath,
};

//
// Builds libwebp for the target.
//
pub fn buildLibwebp(b: *std.Build, target: std.Build.ResolvedTarget) !ILibwebp {
    const library = b.addLibrary(.{
        .name = "webp",
        .linkage = .static,
        .root_module = b.createModule(.{
            .target = target,
            .optimize = .ReleaseFast,
            .link_libc = true,
            .strip = true,
            // The library ends up in Android's shared library, whose code must not depend on where it is loaded.
            .pic = if (target.result.abi.isAndroid()) true else null,
        }),
    });
    const module = library.root_module;
    // The library includes its own headers as "src/webp/types.h" and "sharpyuv/sharpyuv.h", from its root.
    module.addIncludePath(b.path("vendor/libwebp"));
    const directories = [_][]const u8{
        "vendor/libwebp/src/dec",
        "vendor/libwebp/src/dsp",
        "vendor/libwebp/src/enc",
        "vendor/libwebp/src/utils",
        "vendor/libwebp/sharpyuv",
    };
    for (directories) |directory| {
        module.addCSourceFiles(.{
            .root = b.path("."),
            .files = try imagemagick.sourceFiles(b, directory, &.{}),
            .flags = &.{"-O2"},
        });
    }
    return .{
        .library = library,
        .include_directory = b.path("vendor/libwebp/src"),
    };
}
