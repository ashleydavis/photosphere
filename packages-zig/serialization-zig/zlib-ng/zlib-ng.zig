const std = @import("std");

//
// Builds zlib-ng 2.3.3 from the unmodified upstream release tarball fetched as the "zlib-ng" dependency in
// build.zig.zon, the way its CMakeLists.txt builds the static library for a Release build with ZLIB_COMPAT on and the
// other options at their defaults (WITH_OPTIM, WITH_GZFILEOP, WITH_NEW_STRATEGIES, WITH_CRC32_CHORBA and
// WITH_RUNTIME_CPU_DETECTION on, WITH_NATIVE_INSTRUCTIONS and WITH_REDUCED_MEM off, no ZLIB_SYMBOL_PREFIX): the same
// source files, the same per-file CPU flags (as the CPU features Zig's C compiler turns them into), the defines of its
// feature checks and the zconf.h, zlib.h, zlib_name_mangling.h and gzread_mangle.h it generates (byte-identical to
// the ones CMake writes).
//
// The feature check results below are what CMake 3.28 finds when zlib-ng's CMakeLists.txt is configured with Zig's C
// compiler (`zig cc -target <triple>`) for x86_64-linux-gnu, x86_64-linux-musl, aarch64-linux-gnu,
// aarch64-linux-musl, x86_64-windows-gnu, x86_64-macos and aarch64-macos, read from its compile_commands.json. To
// re-check them on an upgrade, configure the new release the same way for each target:
//
//     cmake -S <zlib-ng> -B <build> -G Ninja -DCMAKE_SYSTEM_NAME=<Linux|Windows|Darwin>
//         -DCMAKE_SYSTEM_PROCESSOR=<x86_64|aarch64> -DCMAKE_C_COMPILER_TARGET=<x86_64|aarch64>
//         -DCMAKE_C_COMPILER=<script running `zig cc -target <triple>`> -DZLIB_COMPAT=ON -DBUILD_SHARED_LIBS=OFF
//         -DBUILD_TESTING=OFF -DCMAKE_EXPORT_COMPILE_COMMANDS=ON
//
// CMAKE_C_COMPILER_TARGET is what cmake/detect-arch.cmake takes as ARCH when cross-compiling (natively its
// detect-arch.c probe gives the same name). The script has to drop the `--target=` CMake adds, and on aarch64 turn
// the `-march=armv8-a+<features>` flags of cmake/detect-intrinsics.cmake into `-mcpu=generic+<features>` (with simd
// spelled neon), because `zig cc` only takes CPU names after -march where clang and gcc take these.
//

//
// The name the module translated from zlib.h is imported under.
//
pub const module_name = "zlib";

//
// The target zlib-ng is built for, as CMakeLists.txt tells the platforms apart.
//
const Configuration = struct {
    // True for Linux (CMake: `CMAKE_SYSTEM_NAME STREQUAL "Linux"`).
    isLinux: bool,

    // True for Windows (CMake: `WIN32` and `MINGW`, since Zig targets Windows with the MinGW-w64 ABI).
    isWindows: bool,

    // True for x86_64 (CMake: `BASEARCH_X86_FOUND` with `ARCH` "x86_64"), false for aarch64 (`BASEARCH_ARM_FOUND`).
    isX86_64: bool,
};

//
// The defines every target gets (CMakeLists.txt adds them with add_definitions): ZLIB_COMPAT, WITH_GZFILEOP (on with
// ZLIB_COMPAT), WITH_OPTIM, and the compiler checks HAVE_VISIBILITY_HIDDEN, HAVE_VISIBILITY_INTERNAL,
// HAVE_ATTRIBUTE_ALIGNED, HAVE_BUILTIN_ASSUME_ALIGNED, HAVE_BUILTIN_CTZ and HAVE_BUILTIN_CTZLL, which pass for every
// target. NDEBUG is the Release build's (CMAKE_C_FLAGS_RELEASE).
//
const common_defines = [_][]const u8{
    "ZLIB_COMPAT",
    "WITH_GZFILEOP",
    "WITH_OPTIM",
    "HAVE_VISIBILITY_HIDDEN",
    "HAVE_VISIBILITY_INTERNAL",
    "HAVE_ATTRIBUTE_ALIGNED",
    "HAVE_BUILTIN_ASSUME_ALIGNED",
    "HAVE_BUILTIN_CTZ",
    "HAVE_BUILTIN_CTZLL",
    "NDEBUG",
};

//
// The defines of the large file check, which finds off64_t on Linux and _off64_t on Windows (MinGW-w64), and neither
// on macOS.
//
const largefile_defines = [_][]const u8{
    "_LARGEFILE64_SOURCE=1",
    "__USE_LARGEFILE64",
};

//
// The defines of the header checks that only pass on Linux: sys/auxv.h and linux/auxvec.h.
//
const linux_header_defines = [_][]const u8{
    "HAVE_SYS_AUXV_H",
    "HAVE_LINUX_AUXVEC_H",
};

//
// The defines of the x86 checks: X86_FEATURES, __cpuid_count (HAVE_CPUID_GNU), _xgetbv (X86_HAVE_XSAVE_INTRIN) and
// every SIMD kernel family, whose intrinsics all compile.
//
const x86_64_defines = [_][]const u8{
    "X86_FEATURES",
    "HAVE_CPUID_GNU",
    "X86_HAVE_XSAVE_INTRIN",
    "X86_SSE2",
    "X86_SSSE3",
    "X86_SSE41",
    "X86_SSE42",
    "X86_PCLMULQDQ_CRC",
    "X86_AVX2",
    "X86_AVX512",
    "X86_AVX512VNNI",
    "X86_VPCLMULQDQ_CRC",
};

//
// The defines of the ARM checks on aarch64: ARM_FEATURES, arm_acle.h, the ARMv8 CRC32 inline assembly and intrinsics
// (ARM_CRC32, ARM_CRC32_INTRIN), NEON with vld1q_s32_x4 (ARM_NEON, ARM_NEON_HASLD4). Without the x86_64 SSE2 kernels
// standing in for them, every generic kernel is compiled (WITH_ALL_FALLBACKS).
//
const aarch64_defines = [_][]const u8{
    "ARM_FEATURES",
    "HAVE_ARM_ACLE_H",
    "ARM_CRC32",
    "ARM_CRC32_INTRIN",
    "ARM_NEON",
    "ARM_NEON_HASLD4",
    "WITH_ALL_FALLBACKS",
};

//
// The compiler flags of every source file: C11 without extensions (CMAKE_C_STANDARD 11, CMAKE_C_EXTENSIONS off) and
// the Release build's -O2 (CMakeLists.txt replaces CMake's -O3 with -O2). The warning flags are left out: they change
// what the compiler reports, not what it produces.
//
const common_flags = [_][]const u8{
    "-std=c11",
    "-O2",
};

//
// What building the library and its kernels needs to know.
//
const Context = struct {
    // The build.
    b: *std.Build,

    // The target the library is built for.
    target: std.Build.ResolvedTarget,

    // The platforms CMakeLists.txt tells apart.
    configuration: Configuration,

    // The zlib-ng sources.
    dependency: *std.Build.Dependency,

    // The headers CMakeLists.txt generates in its build directory.
    generated: *std.Build.Step.WriteFile,
};

//
// A group of kernels CMakeLists.txt compiles with extra flags (`set_property(SOURCE ... COMPILE_FLAGS)`).
//
const KernelGroup = struct {
    // The name of the static library the group is compiled into.
    name: []const u8,

    // The source files, relative to the zlib-ng root.
    files: []const []const u8,

    // The CPU features the group's `-m<feature>` flags (on aarch64 the `+<feature>` of `-march=armv8-a+<feature>`)
    // turn on, as Zig's C compiler turns them on: by adding them to the target, which also adds the features they
    // depend on (-mavx512f brings evex512 with it).
    features: []const std.Target.Cpu.Feature.Set.Index,

    // The rest of the group's flags, passed to the compiler as they are.
    flags: []const []const u8,
};

//
// Builds zlib-ng for the target, links it into the module and adds the "zlib" module translated from its zlib.h.
//
pub fn addZlibNg(b: *std.Build, module: *std.Build.Module, target: std.Build.ResolvedTarget) !void {
    const os = target.result.os.tag;
    const arch = target.result.cpu.arch;
    if (os != .linux and os != .windows and os != .macos) {
        std.log.err("zlib-ng is only built for Linux, Windows and macOS, not {s}.", .{@tagName(os)});
        std.process.exit(1);
    }
    if (arch != .x86_64 and arch != .aarch64) {
        std.log.err("The zlib-ng build only covers x86_64 and aarch64, not {s}.", .{@tagName(arch)});
        std.process.exit(1);
    }
    if (os == .windows and arch != .x86_64) {
        std.log.err("The zlib-ng build only covers x86_64 on Windows, not {s}.", .{@tagName(arch)});
        std.process.exit(1);
    }
    const dependency = b.dependency("zlib-ng", .{});
    const context: Context = .{
        .b = b,
        .target = target,
        .configuration = .{
            .isLinux = os == .linux,
            .isWindows = os == .windows,
            .isX86_64 = arch == .x86_64,
        },
        .dependency = dependency,
        .generated = try generateHeaders(b, dependency),
    };

    const library = createLibrary(&context, "z", target);
    // ZLIB_SRCS, with arch/generic/crc32_chorba_c.c (WITH_CRC32_CHORBA) and cpu_features.c
    // (WITH_RUNTIME_CPU_DETECTION), and ZLIB_GZFILE_SRCS (WITH_GZFILEOP).
    library.root_module.addCSourceFiles(.{
        .root = dependency.path(""),
        .files = &.{
            "adler32.c",
            "compress.c",
            "crc32.c",
            "crc32_braid_comb.c",
            "deflate.c",
            "deflate_fast.c",
            "deflate_huff.c",
            "deflate_medium.c",
            "deflate_quick.c",
            "deflate_rle.c",
            "deflate_slow.c",
            "deflate_stored.c",
            "functable.c",
            "infback.c",
            "inflate.c",
            "inftrees.c",
            "insert_string.c",
            "insert_string_roll.c",
            "trees.c",
            "uncompr.c",
            "zutil.c",
            "arch/generic/crc32_chorba_c.c",
            "cpu_features.c",
            "gzlib.c",
            "gzread.c",
            "gzwrite.c",
        },
        .flags = &common_flags,
    });
    const kernel_groups: []const KernelGroup = if (context.configuration.isX86_64) &x86_64_kernel_groups else &aarch64_kernel_groups;
    for (kernel_groups) |group| {
        try addKernelGroup(&context, library, group);
    }

    const translate_c = b.addTranslateC(.{
        .root_source_file = context.generated.getDirectory().path(b, "zlib.h"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    translate_c.addIncludePath(context.generated.getDirectory());
    module.addImport(module_name, translate_c.createModule());
    module.linkLibrary(library);
}

//
// The x86_64 kernels and their flags, from the X86 section of CMakeLists.txt and the flags of
// cmake/detect-intrinsics.cmake.
//
const x86_64_kernel_groups = [_]KernelGroup{
    .{
        // The generic kernels the SSE2 ones do not stand in for (compare256_c.c is not needed with HAVE_BUILTIN_CTZ),
        // and the SSE2 kernels, which need no flag on x86_64.
        .name = "z",
        .files = &.{
            "arch/generic/adler32_c.c",
            "arch/generic/adler32_fold_c.c",
            "arch/generic/crc32_braid_c.c",
            "arch/generic/crc32_fold_c.c",
            "arch/x86/chunkset_sse2.c",
            "arch/x86/chorba_sse2.c",
            "arch/x86/compare256_sse2.c",
            "arch/x86/slide_hash_sse2.c",
        },
        .features = &.{},
        .flags = &.{},
    },
    .{
        // -mxsave (XSAVEFLAG).
        .name = "z-xsave",
        .files = &.{
            "arch/x86/x86_features.c",
        },
        .features = &.{
            @intFromEnum(std.Target.x86.Feature.xsave),
        },
        .flags = &.{},
    },
    .{
        // -mssse3 (SSSE3FLAG).
        .name = "z-ssse3",
        .files = &.{
            "arch/x86/adler32_ssse3.c",
            "arch/x86/chunkset_ssse3.c",
        },
        .features = &.{
            @intFromEnum(std.Target.x86.Feature.ssse3),
        },
        .flags = &.{
            "-fno-lto",
        },
    },
    .{
        // -msse4.1 (SSE41FLAG).
        .name = "z-sse41",
        .files = &.{
            "arch/x86/chorba_sse41.c",
        },
        .features = &.{
            @intFromEnum(std.Target.x86.Feature.sse4_1),
        },
        .flags = &.{
            "-fno-lto",
        },
    },
    .{
        // -msse4.2 (SSE42FLAG).
        .name = "z-sse42",
        .files = &.{
            "arch/x86/adler32_sse42.c",
        },
        .features = &.{
            @intFromEnum(std.Target.x86.Feature.sse4_2),
        },
        .flags = &.{
            "-fno-lto",
        },
    },
    .{
        // -msse4.2 -mpclmul (SSE42FLAG and PCLMULFLAG).
        .name = "z-pclmulqdq",
        .files = &.{
            "arch/x86/crc32_pclmulqdq.c",
        },
        .features = &.{
            @intFromEnum(std.Target.x86.Feature.sse4_2),
            @intFromEnum(std.Target.x86.Feature.pclmul),
        },
        .flags = &.{
            "-fno-lto",
        },
    },
    .{
        // -mavx2 -mbmi2 (AVX2FLAG).
        .name = "z-avx2",
        .files = &.{
            "arch/x86/slide_hash_avx2.c",
            "arch/x86/chunkset_avx2.c",
            "arch/x86/compare256_avx2.c",
            "arch/x86/adler32_avx2.c",
        },
        .features = &.{
            @intFromEnum(std.Target.x86.Feature.avx2),
            @intFromEnum(std.Target.x86.Feature.bmi2),
        },
        .flags = &.{
            "-fno-lto",
        },
    },
    .{
        // -mavx512f -mavx512dq -mavx512bw -mavx512vl -mbmi2 -mtune=cascadelake (AVX512FLAG, with the -mtune it adds
        // when the compiler takes it).
        .name = "z-avx512",
        .files = &.{
            "arch/x86/adler32_avx512.c",
            "arch/x86/chunkset_avx512.c",
            "arch/x86/compare256_avx512.c",
        },
        .features = &.{
            @intFromEnum(std.Target.x86.Feature.avx512f),
            @intFromEnum(std.Target.x86.Feature.avx512dq),
            @intFromEnum(std.Target.x86.Feature.avx512bw),
            @intFromEnum(std.Target.x86.Feature.avx512vl),
            @intFromEnum(std.Target.x86.Feature.bmi2),
        },
        .flags = &.{
            "-mtune=cascadelake",
            "-fno-lto",
        },
    },
    .{
        // AVX512FLAG with -mavx512vnni (AVX512VNNIFLAG).
        .name = "z-avx512vnni",
        .files = &.{
            "arch/x86/adler32_avx512_vnni.c",
        },
        .features = &.{
            @intFromEnum(std.Target.x86.Feature.avx512f),
            @intFromEnum(std.Target.x86.Feature.avx512dq),
            @intFromEnum(std.Target.x86.Feature.avx512bw),
            @intFromEnum(std.Target.x86.Feature.avx512vl),
            @intFromEnum(std.Target.x86.Feature.avx512vnni),
            @intFromEnum(std.Target.x86.Feature.bmi2),
        },
        .flags = &.{
            "-mtune=cascadelake",
            "-fno-lto",
        },
    },
    .{
        // -mpclmul -mvpclmulqdq -mavx512f and AVX512FLAG (PCLMULFLAG, VPCLMULFLAG and AVX512FLAG).
        .name = "z-vpclmulqdq",
        .files = &.{
            "arch/x86/crc32_vpclmulqdq.c",
        },
        .features = &.{
            @intFromEnum(std.Target.x86.Feature.pclmul),
            @intFromEnum(std.Target.x86.Feature.vpclmulqdq),
            @intFromEnum(std.Target.x86.Feature.avx512f),
            @intFromEnum(std.Target.x86.Feature.avx512dq),
            @intFromEnum(std.Target.x86.Feature.avx512bw),
            @intFromEnum(std.Target.x86.Feature.avx512vl),
            @intFromEnum(std.Target.x86.Feature.bmi2),
        },
        .flags = &.{
            "-mtune=cascadelake",
            "-fno-lto",
        },
    },
};

//
// The aarch64 kernels and their flags, from the ARM section of CMakeLists.txt and the flags of
// cmake/detect-intrinsics.cmake.
//
const aarch64_kernel_groups = [_]KernelGroup{
    .{
        // Every generic kernel (ZLIB_ALL_FALLBACK_SRCS) and arm_features.c (WITH_RUNTIME_CPU_DETECTION).
        .name = "z",
        .files = &.{
            "arch/generic/adler32_c.c",
            "arch/generic/adler32_fold_c.c",
            "arch/generic/chunkset_c.c",
            "arch/generic/compare256_c.c",
            "arch/generic/crc32_braid_c.c",
            "arch/generic/crc32_fold_c.c",
            "arch/generic/slide_hash_c.c",
            "arch/arm/arm_features.c",
        },
        .features = &.{},
        .flags = &.{},
    },
    .{
        // -march=armv8-a+crc (ARMV8FLAG).
        .name = "z-armv8",
        .files = &.{
            "arch/arm/crc32_armv8.c",
        },
        .features = &.{
            @intFromEnum(std.Target.aarch64.Feature.crc),
        },
        .flags = &.{
            "-fno-lto",
        },
    },
    .{
        // -march=armv8-a+simd (NEONFLAG).
        .name = "z-neon",
        .files = &.{
            "arch/arm/adler32_neon.c",
            "arch/arm/chunkset_neon.c",
            "arch/arm/compare256_neon.c",
            "arch/arm/slide_hash_neon.c",
        },
        .features = &.{
            @intFromEnum(std.Target.aarch64.Feature.neon),
        },
        .flags = &.{
            "-fno-lto",
        },
    },
};

//
// Creates a static library of zlib-ng sources for a target, with the include paths and defines CMakeLists.txt gives
// every source file. Optimized and without debug information, like the CMake Release build (-O2 -DNDEBUG, no -g),
// whatever mode the Zig code is built in.
//
fn createLibrary(context: *const Context, name: []const u8, target: std.Build.ResolvedTarget) *std.Build.Step.Compile {
    const library = context.b.addLibrary(.{
        .name = name,
        .linkage = .static,
        .root_module = context.b.createModule(.{
            .target = target,
            .optimize = .ReleaseFast,
            .link_libc = true,
            .strip = true,
        }),
    });
    const module = library.root_module;
    // target_include_directories: the build directory (the generated headers) and the source directory.
    module.addIncludePath(context.generated.getDirectory());
    module.addIncludePath(context.dependency.path(""));
    const configuration = context.configuration;
    addDefines(module, &common_defines);
    if (configuration.isLinux or configuration.isWindows) {
        addDefines(module, &largefile_defines);
    }
    if (configuration.isLinux) {
        addDefines(module, &linux_header_defines);
    }
    if (configuration.isX86_64) {
        addDefines(module, &x86_64_defines);
        // __cpuid (HAVE_CPUID_MS) is only found in MinGW-w64's intrin.h.
        if (configuration.isWindows) {
            addDefines(module, &.{"HAVE_CPUID_MS"});
        }
    }
    else {
        addDefines(module, &aarch64_defines);
        // getauxval(AT_HWCAP) & HWCAP_CRC32 compiles against Linux's sys/auxv.h.
        if (configuration.isLinux) {
            addDefines(module, &.{"ARM_AUXV_HAS_CRC32"});
        }
    }
    return library;
}

//
// Adds a group of kernels to the library: directly when it needs no extra CPU features, otherwise compiled into a
// static library of its own for the target with those features, linked into the library.
//
fn addKernelGroup(context: *const Context, library: *std.Build.Step.Compile, group: KernelGroup) !void {
    var groupLibrary = library;
    if (group.features.len > 0) {
        var query = context.target.query;
        for (group.features) |feature| {
            query.cpu_features_add.addFeature(feature);
        }
        groupLibrary = createLibrary(context, group.name, context.b.resolveTargetQuery(query));
        library.root_module.linkLibrary(groupLibrary);
    }
    groupLibrary.root_module.addCSourceFiles(.{
        .root = context.dependency.path(""),
        .files = group.files,
        .flags = try std.mem.concat(context.b.allocator, []const u8, &.{ &common_flags, group.flags }),
    });
}

//
// Adds defines given as CMake's add_definitions takes them: `NAME` or `NAME=VALUE`.
//
fn addDefines(module: *std.Build.Module, defineList: []const []const u8) void {
    for (defineList) |define| {
        if (std.mem.indexOfScalar(u8, define, '=')) |index| {
            module.addCMacro(define[0..index], define[index + 1 ..]);
        }
        else {
            module.addCMacro(define, "1");
        }
    }
}

//
// Generates the headers CMakeLists.txt writes to its build directory: zconf.h (generate_cmakein, then configure_file),
// zlib.h and gzread_mangle.h (configure_file) and zlib_name_mangling.h (a copy of zlib_name_mangling.h.empty, since
// ZLIB_SYMBOL_PREFIX is not set).
//
fn generateHeaders(b: *std.Build, dependency: *std.Build.Dependency) !*std.Build.Step.WriteFile {
    const generated = b.addWriteFiles();
    _ = generated.add("zconf.h", try configureFile(b, try generateCmakein(b, try readSource(b, dependency, "zconf.h.in"))));
    _ = generated.add("zlib.h", try configureFile(b, try readSource(b, dependency, "zlib.h.in")));
    _ = generated.add("gzread_mangle.h", try configureFile(b, try readSource(b, dependency, "gzread_mangle.h.in")));
    _ = generated.add("zlib_name_mangling.h", try readSource(b, dependency, "zlib_name_mangling.h.empty"));
    return generated;
}

//
// Reads a file of the zlib-ng sources.
//
fn readSource(b: *std.Build, dependency: *std.Build.Dependency, name: []const u8) ![]u8 {
    return dependency.builder.build_root.handle.readFileAlloc(b.graph.io, name, b.allocator, .unlimited);
}

//
// The generate_cmakein macro of CMakeLists.txt followed by configure_file's filling in of the placeholders it leaves:
// the rest of the line from `#ifdef HAVE_UNISTD_H` becomes ZCONF_UNISTD_LINE, set to `#if 1` because unistd.h is found
// on every supported target (MinGW-w64 has one), and the rest of the line from `#ifdef NEED_PTRDIFF_T` becomes
// ZCONF_PTRDIFF_LINE, which keeps the `#ifdef` because ptrdiff_t is found.
//
fn generateCmakein(b: *std.Build, template: []const u8) ![]u8 {
    var output: std.ArrayList(u8) = .empty;
    var lines = std.mem.splitScalar(u8, template, '\n');
    var isFirstLine = true;
    while (lines.next()) |line| {
        if (!isFirstLine) {
            try output.append(b.allocator, '\n');
        }
        isFirstLine = false;
        if (std.mem.indexOf(u8, line, "#ifdef HAVE_UNISTD_H")) |index| {
            try output.appendSlice(b.allocator, line[0..index]);
            try output.appendSlice(b.allocator, "#if 1    /* was set to #if 1 by configure/cmake/etc */");
        }
        else if (std.mem.indexOf(u8, line, "#ifdef NEED_PTRDIFF_T")) |index| {
            try output.appendSlice(b.allocator, line[0..index]);
            try output.appendSlice(b.allocator, "#ifdef NEED_PTRDIFF_T    /* may be set to #if 1 by configure/cmake/etc */");
        }
        else {
            try output.appendSlice(b.allocator, line);
        }
    }
    return output.items;
}

//
// True for the characters CMake's configure_file accepts in the name of an @VAR@ reference.
//
fn isVariableCharacter(character: u8) bool {
    return std.ascii.isAlphanumeric(character) or character == '_' or character == '/' or character == '.' or character == '+' or character == '-';
}

//
// CMake's configure_file with @ONLY, for the files zlib-ng configures: every @VAR@ reference is replaced with the
// variable's value. The only variable they reference is ZLIB_SYMBOL_PREFIX, which is empty, so each reference is
// removed.
//
fn configureFile(b: *std.Build, template: []const u8) ![]u8 {
    var output: std.ArrayList(u8) = .empty;
    var index: usize = 0;
    while (index < template.len) {
        if (template[index] == '@') {
            var end = index + 1;
            while (end < template.len and isVariableCharacter(template[end])) {
                end += 1;
            }
            if (end > index + 1 and end < template.len and template[end] == '@') {
                index = end + 1;
                continue;
            }
        }
        try output.append(b.allocator, template[index]);
        index += 1;
    }
    return output.items;
}
