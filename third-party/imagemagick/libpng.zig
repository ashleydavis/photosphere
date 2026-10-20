const std = @import("std");

//
// Builds libpng from the unmodified source in vendor/libpng, the way its CMakeLists.txt builds the static library: the same
// source files and the pnglibconf.h it ships ready made (scripts/pnglibconf.h.prebuilt, which is what its
// makefiles copy when no custom configuration is asked for). The optimised filters for particular processors (NEON, SSE2,
// MSA, VSX, LSX and RVV) are switched off, as CMake does when PNG_HARDWARE_OPTIMIZATIONS is off, so one set of source files
// serves every target.
//

//
// libpng built for a target.
//
pub const ILibpng = struct {
    // The static library.
    library: *std.Build.Step.Compile,

    // The directory that holds png.h, pngconf.h and pnglibconf.h, for the C code that includes them.
    include_directory: std.Build.LazyPath,
};

//
// The files of the library: PNG_LIB_SOURCES of vendor/libpng/CMakeLists.txt without the processor specific ones.
//
const library_files = [_][]const u8{
    "png.c",
    "pngerror.c",
    "pngget.c",
    "pngmem.c",
    "pngpread.c",
    "pngread.c",
    "pngrio.c",
    "pngrtran.c",
    "pngrutil.c",
    "pngset.c",
    "pngtrans.c",
    "pngwio.c",
    "pngwrite.c",
    "pngwtran.c",
    "pngwutil.c",
};

//
// Builds libpng for the target, over the zlib in the directory (its zlib.h and zconf.h).
//
pub fn buildLibpng(b: *std.Build, target: std.Build.ResolvedTarget, zlib_include_directory: std.Build.LazyPath) ILibpng {
    const headers = b.addWriteFiles();
    _ = headers.addCopyFile(b.path("vendor/libpng/png.h"), "png.h");
    _ = headers.addCopyFile(b.path("vendor/libpng/pngconf.h"), "pngconf.h");
    _ = headers.addCopyFile(b.path("vendor/libpng/scripts/pnglibconf.h.prebuilt"), "pnglibconf.h");

    const library = b.addLibrary(.{
        .name = "png",
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
    library.root_module.addIncludePath(headers.getDirectory());
    library.root_module.addIncludePath(zlib_include_directory);
    library.root_module.addIncludePath(b.path("vendor/libpng"));
    library.root_module.addCSourceFiles(.{
        .root = b.path("vendor/libpng"),
        .files = &library_files,
        .flags = &.{
            "-O2",
            "-DPNG_ARM_NEON_OPT=0",
            "-DPNG_INTEL_SSE_OPT=0",
            "-DPNG_MIPS_MSA_OPT=0",
            "-DPNG_POWERPC_VSX_OPT=0",
            "-DPNG_LOONGARCH_LSX_OPT=0",
            "-DPNG_RISCV_RVV_OPT=0",
        },
    });
    return .{
        .library = library,
        .include_directory = headers.getDirectory(),
    };
}
