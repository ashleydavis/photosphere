const std = @import("std");
const imagemagick = @import("../imagemagick/imagemagick.zig");

//
// Builds libwebp from the unmodified source in vendor/libwebp as a static library: the decoder, the encoder, their shared code
// and the sharpyuv library the encoder uses, the same directories its CMakeLists.txt builds into libwebp, with no flags for a
// particular processor (but on Windows with the MSVC ABI, below). The code for SSE4.1, AVX2 and the like is in files that compile to nothing unless the compiler turns the
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
    // With the MSVC ABI libwebp turns its SSE4.1 and AVX2 code on whatever the compiler was told (cpu.h: WEBP_MSC_SSE41 and
    // WEBP_MSC_AVX2, since Microsoft's compiler takes the intrinsics without flags), so for clang the files that hold it are compiled
    // with those features, as libwebp's own CMake build compiles them, each kind in a static library of its own whose target adds the
    // feature (Zig takes the processor's features from the target, not from -m flags). The code checks the processor before it runs any
    // of it.
    const is_msvc = target.result.os.tag == .windows and target.result.abi == .msvc;
    var sse41_files: std.ArrayList([]const u8) = .empty;
    var avx2_files: std.ArrayList([]const u8) = .empty;
    for (directories) |directory| {
        var baseline_files: std.ArrayList([]const u8) = .empty;
        for (try imagemagick.sourceFiles(b, directory, &.{})) |file| {
            if (is_msvc and std.mem.endsWith(u8, file, "_sse41.c")) {
                try sse41_files.append(b.allocator, file);
            }
            else if (is_msvc and std.mem.endsWith(u8, file, "_avx2.c")) {
                try avx2_files.append(b.allocator, file);
            }
            else {
                try baseline_files.append(b.allocator, file);
            }
        }
        module.addCSourceFiles(.{
            .root = b.path("."),
            .files = baseline_files.items,
            .flags = &.{"-O2"},
        });
    }
    if (sse41_files.items.len > 0) {
        module.linkLibrary(featureLibrary(b, target, "webp-sse41", &.{ .ssse3, .sse4_1 }, sse41_files.items));
    }
    if (avx2_files.items.len > 0) {
        module.linkLibrary(featureLibrary(b, target, "webp-avx2", &.{.avx2}, avx2_files.items));
    }
    return .{
        .library = library,
        .include_directory = b.path("vendor/libwebp/src"),
    };
}

//
// Builds libwebp's source files that hold code for the given x86 features as a static library of its own, for the target with those
// features added.
//
fn featureLibrary(b: *std.Build, target: std.Build.ResolvedTarget, name: []const u8, features: []const std.Target.x86.Feature, files: []const []const u8) *std.Build.Step.Compile {
    var query = target.query;
    for (features) |feature| {
        query.cpu_features_add.addFeature(@intFromEnum(feature));
    }
    const library = b.addLibrary(.{
        .name = name,
        .linkage = .static,
        .root_module = b.createModule(.{
            .target = b.resolveTargetQuery(query),
            .optimize = .ReleaseFast,
            .link_libc = true,
            .strip = true,
        }),
    });
    library.root_module.addIncludePath(b.path("vendor/libwebp"));
    library.root_module.addCSourceFiles(.{
        .root = b.path("."),
        .files = files,
        .flags = &.{"-O2"},
    });
    return library;
}
