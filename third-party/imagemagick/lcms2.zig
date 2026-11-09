const std = @import("std");
const imagemagick = @import("imagemagick.zig");

//
// Builds Little CMS 2 (lcms2) from the unmodified source in vendor/lcms2 as a static library: every .c file of src, the files of
// liblcms2_la_SOURCES in its src/Makefile.am. It is the colour management delegate ImageMagick converts pixels from one ICC profile to
// another with. Nothing is configured: lcms2 works out the C library and the processor from the compiler's own macros, and uses the
// thread functions of the target (pthreads, or Windows' own) unless told not to.
//

//
// lcms2 built for a target.
//
pub const ILcms2 = struct {
    // The static library.
    library: *std.Build.Step.Compile,

    // The directory that holds lcms2.h, for the C code that includes it.
    include_directory: std.Build.LazyPath,
};

//
// Builds lcms2 for the target.
//
pub fn buildLcms2(b: *std.Build, target: std.Build.ResolvedTarget) !ILcms2 {
    const library = b.addLibrary(.{
        .name = "lcms2",
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
    library.root_module.addIncludePath(b.path("vendor/lcms2/include"));
    library.root_module.addCSourceFiles(.{
        .root = b.path("."),
        .files = try imagemagick.sourceFiles(b, "vendor/lcms2/src", &.{}),
        .flags = &.{"-O2"},
    });
    return .{
        .library = library,
        .include_directory = b.path("vendor/lcms2/include"),
    };
}
