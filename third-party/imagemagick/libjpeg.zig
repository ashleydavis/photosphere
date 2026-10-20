const std = @import("std");

//
// Builds the Independent JPEG Group's libjpeg from the unmodified source in vendor/libjpeg, the way its configure script and
// Makefile.am build the static library: the same source files (with jmemnobs.c as the memory manager, which is what
// configure picks when --enable-maxmem is not given) and a jconfig.h made from jconfig.cfg with the answers configure's
// checks give on every target Photosphere is built for.
//

//
// libjpeg built for a target.
//
pub const ILibjpeg = struct {
    // The static library.
    library: *std.Build.Step.Compile,

    // The configuration header (jconfig.h), which jpeglib.h includes.
    config_header: *std.Build.Step.ConfigHeader,

    // The directory that holds jpeglib.h, jmorecfg.h and jerror.h, for the C code that includes them.
    include_directory: std.Build.LazyPath,
};

//
// The files of the library: LIBSOURCES of vendor/libjpeg/Makefile.am with jmemnobs.c for @MEMORYMGR@.
//
const library_files = [_][]const u8{
    "jaricom.c",
    "jcapimin.c",
    "jcapistd.c",
    "jcarith.c",
    "jccoefct.c",
    "jccolor.c",
    "jcdctmgr.c",
    "jchuff.c",
    "jcinit.c",
    "jcmainct.c",
    "jcmarker.c",
    "jcmaster.c",
    "jcomapi.c",
    "jcparam.c",
    "jcprepct.c",
    "jcsample.c",
    "jctrans.c",
    "jdapimin.c",
    "jdapistd.c",
    "jdarith.c",
    "jdatadst.c",
    "jdatasrc.c",
    "jdcoefct.c",
    "jdcolor.c",
    "jddctmgr.c",
    "jdhuff.c",
    "jdinput.c",
    "jdmainct.c",
    "jdmarker.c",
    "jdmaster.c",
    "jdmerge.c",
    "jdpostct.c",
    "jdsample.c",
    "jdtrans.c",
    "jerror.c",
    "jfdctflt.c",
    "jfdctfst.c",
    "jfdctint.c",
    "jidctflt.c",
    "jidctfst.c",
    "jidctint.c",
    "jquant1.c",
    "jquant2.c",
    "jutils.c",
    "jmemmgr.c",
    "jmemnobs.c",
};

//
// Builds libjpeg for the target.
//
pub fn buildLibjpeg(b: *std.Build, target: std.Build.ResolvedTarget) ILibjpeg {
    // jconfig.cfg is configure's template. HAVE_PROTOTYPES, HAVE_UNSIGNED_CHAR, HAVE_UNSIGNED_SHORT, HAVE_STDDEF_H, HAVE_STDLIB_H
    // and HAVE_LOCALE_H pass on every target. The rest of the template's symbols are left undefined, which is what configure
    // does when its check fails or the target needs no workaround: void and const (the compiler knows both), CHAR_IS_UNSIGNED
    // (leaving it undefined works at some cost in speed), NEED_BSD_STRINGS, NEED_SYS_TYPES_H, NEED_FAR_POINTERS,
    // NEED_SHORT_EXTERNAL_NAMES, INCOMPLETE_TYPES_BROKEN, RIGHT_SHIFT_IS_UNSIGNED (shifts of signed values are arithmetic on
    // every compiler used here), INLINE (jmorecfg.h defines it for GCC and Clang), DEFAULT_MAX_MEM (jmemnobs.c does not use
    // it) and NO_MKTEMP.
    const config_header = b.addConfigHeader(.{
        .style = .{
            .autoconf_undef = b.path("vendor/libjpeg/jconfig.cfg"),
        },
        .include_path = "jconfig.h",
    }, .{
        .HAVE_PROTOTYPES = 1,
        .HAVE_UNSIGNED_CHAR = 1,
        .HAVE_UNSIGNED_SHORT = 1,
        .HAVE_STDDEF_H = 1,
        .HAVE_STDLIB_H = 1,
        .HAVE_LOCALE_H = 1,
        .@"void" = null,
        .@"const" = null,
        .CHAR_IS_UNSIGNED = null,
        .NEED_BSD_STRINGS = null,
        .NEED_SYS_TYPES_H = null,
        .NEED_FAR_POINTERS = null,
        .NEED_SHORT_EXTERNAL_NAMES = null,
        .INCOMPLETE_TYPES_BROKEN = null,
        .RIGHT_SHIFT_IS_UNSIGNED = null,
        .INLINE = null,
        .DEFAULT_MAX_MEM = null,
        .NO_MKTEMP = null,
        // The symbols of the command line programs cjpeg and djpeg, which are not built.
        .RLE_SUPPORTED = null,
        .TWO_FILE_COMMANDLINE = null,
        .NEED_SIGNAL_CATCHER = null,
        .DONT_USE_B_MODE = null,
        .PROGRESS_REPORT = null,
    });
    const headers = b.addWriteFiles();
    _ = headers.addCopyFile(b.path("vendor/libjpeg/jpeglib.h"), "jpeglib.h");
    _ = headers.addCopyFile(b.path("vendor/libjpeg/jmorecfg.h"), "jmorecfg.h");
    _ = headers.addCopyFile(b.path("vendor/libjpeg/jerror.h"), "jerror.h");

    const library = b.addLibrary(.{
        .name = "jpeg",
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
    library.root_module.addConfigHeader(config_header);
    library.root_module.addIncludePath(b.path("vendor/libjpeg"));
    library.root_module.addCSourceFiles(.{
        .root = b.path("vendor/libjpeg"),
        .files = &library_files,
        .flags = &.{"-O2"},
    });
    return .{
        .library = library,
        .config_header = config_header,
        .include_directory = headers.getDirectory(),
    };
}
