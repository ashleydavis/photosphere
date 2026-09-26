const std = @import("std");
const aws_sdk = @import("aws-sdk.zig");

//
// Builds aws-c-common as its CMakeLists.txt does, with the compiler flags of its cmake/AwsCFlags.cmake and the
// feature test results of its cmake/AwsFeatureTests.cmake and cmake/AwsSIMD.cmake for the target (evaluated with Zig's
// C compiler for each target; docs/aws-sdk.md says how to re-check them on an upgrade).
//

//
// True when aws-c-common's `USE_CPU_EXTENSIONS` is on. AwsFeatureTests.cmake turns it off for MinGW, which is the ABI
// Zig uses for Windows.
//
pub fn useCpuExtensions(context: *const aws_sdk.Context) bool {
    return !context.isWindows;
}

//
// The target the aws-c-* libraries are compiled for: aws_set_common_properties (AwsCFlags.cmake) adds
// `-moutline-atomics` on ARM64 when the compiler supports it, which Zig's does.
//
pub fn libraryTarget(context: *const aws_sdk.Context) std.Build.ResolvedTarget {
    if (context.isAarch64) {
        return context.targetWithFeatures(&.{@intFromEnum(std.Target.aarch64.Feature.outline_atomics)});
    }
    return context.target;
}

//
// Creates the static library of an aws-c-* library.
//
pub fn createLibrary(context: *const aws_sdk.Context, name: []const u8) *std.Build.Step.Compile {
    return context.createLibraryForTarget(name, libraryTarget(context));
}

//
// The compiler flags aws_set_common_properties (AwsCFlags.cmake) gives every aws-c-* library, for a Release build:
// C99 with GNU extensions (`C_STANDARD 99`), hidden visibility, and `-D_FILE_OFFSET_BITS=64` where off_t is not 64 bits
// by default (Windows; on Linux and macOS it is). The warning flags are left out: they change what the compiler
// reports, not what it produces.
//
pub fn commonFlags(context: *const aws_sdk.Context) []const []const u8 {
    if (context.isWindows) {
        return &.{ "-std=gnu99", "-fvisibility=hidden", "-D_FILE_OFFSET_BITS=64" };
    }
    return &.{ "-std=gnu99", "-fvisibility=hidden" };
}

//
// Adds the private defines aws_set_common_properties (AwsCFlags.cmake) gives every aws-c-* library.
//
pub fn addCommonDefines(context: *const aws_sdk.Context, module: *std.Build.Module) void {
    // HAVE_SYSCONF: the sysconf(_SC_NPROCESSORS_ONLN) check compiles on Linux and macOS, not on Windows.
    if (context.isLinux or context.isMacos) {
        module.addCMacro("HAVE_SYSCONF", "1");
    }
    // AWS_ENABLE_TRACING is off.
    module.addCMacro("INTEL_NO_ITTNOTIFY_API", "1");
}

//
// Builds aws-c-common.
//
pub fn build(context: *const aws_sdk.Context, dependency: *std.Build.Dependency) !*std.Build.Step.Compile {
    const b = context.b;
    const library = createLibrary(context, "aws-c-common");
    const module = library.root_module;
    const extensions = useCpuExtensions(context);

    const config_header = b.addConfigHeader(.{
        .style = .{ .cmake = dependency.path("include/aws/common/config.h.in") },
        .include_path = "aws/common/config.h",
    }, .{
        // check_c_source_runs, which CMake only runs when it is not cross-compiling.
        .AWS_HAVE_GCC_OVERFLOW_MATH_EXTENSIONS = !context.isCrossCompiling,
        .AWS_HAVE_GCC_INLINE_ASM = true,
        .AWS_HAVE_MSVC_INTRINSICS_X64 = false,
        .AWS_HAVE_POSIX_LARGE_FILE_SUPPORT = true,
        // execinfo.h is in glibc and macOS, not in musl.
        .AWS_HAVE_EXECINFO = (context.isLinux and !context.isMusl) or context.isMacos,
        .AWS_HAVE_WINAPI_DESKTOP = context.isWindows,
        .AWS_HAVE_LINUX_IF_LINK_H = context.isLinux,
        .AWS_HAVE_AVX2_INTRINSICS = extensions and context.isX86_64,
        .AWS_HAVE_AVX512_INTRINSICS = extensions and context.isX86_64,
        .AWS_HAVE_MM256_EXTRACT_EPI64 = extensions and context.isX86_64,
        .AWS_HAVE_CLMUL = extensions and context.isX86_64,
        .AWS_HAVE_ARM32_CRC = extensions and context.isAarch64,
        .AWS_HAVE_ARMv8_1 = extensions and context.isAarch64,
        .AWS_ARCH_ARM64 = context.isAarch64,
        .AWS_ARCH_INTEL = context.isX86_64,
        .AWS_ARCH_INTEL_X64 = context.isX86_64,
        .AWS_USE_CPU_EXTENSIONS = extensions,
    });

    var sources: std.ArrayList([]const u8) = .empty;
    try sources.appendSlice(b.allocator, try aws_sdk.globCSources(b, dependency, "source"));
    if (context.isWindows) {
        try sources.appendSlice(b.allocator, try aws_sdk.globCSources(b, dependency, "source/windows"));
        try sources.append(b.allocator, "source/platform_fallback_stubs/system_info.c");
        try sources.append(b.allocator, "source/platform_fallback_stubs/file_direct_io.c");
    }
    else if (context.isMacos) {
        try sources.appendSlice(b.allocator, try aws_sdk.globCSources(b, dependency, "source/posix"));
        // "source/darwin/*.c" matches nothing in this release (it has no source/darwin directory).
        try sources.appendSlice(b.allocator, try aws_sdk.globCSources(b, dependency, "source/darwin"));
        try sources.append(b.allocator, "source/platform_fallback_stubs/system_info.c");
        try sources.append(b.allocator, "source/platform_fallback_stubs/file_direct_io.c");
    }
    else {
        try sources.appendSlice(b.allocator, try aws_sdk.globCSources(b, dependency, "source/posix"));
        try sources.appendSlice(b.allocator, try aws_sdk.globCSources(b, dependency, "source/linux"));
    }
    if (extensions and context.isX86_64) {
        try sources.append(b.allocator, "source/arch/intel/cpuid.c");
        try sources.appendSlice(b.allocator, try aws_sdk.globCSources(b, dependency, "source/arch/intel/asm"));
    }
    else if (extensions and context.isAarch64 and context.isMacos) {
        try sources.appendSlice(b.allocator, try aws_sdk.globCSources(b, dependency, "source/arch/arm/darwin"));
    }
    else if (extensions and context.isAarch64) {
        try sources.appendSlice(b.allocator, try aws_sdk.globCSources(b, dependency, "source/arch/arm/auxv"));
    }
    else {
        try sources.appendSlice(b.allocator, try aws_sdk.globCSources(b, dependency, "source/arch/generic"));
    }
    try sources.appendSlice(b.allocator, try aws_sdk.globCSources(b, dependency, "source/external"));
    try sources.appendSlice(b.allocator, try aws_sdk.globCSources(b, dependency, "source/external/libcbor"));
    try sources.appendSlice(b.allocator, try aws_sdk.globCSources(b, dependency, "source/external/libcbor/cbor"));
    try sources.appendSlice(b.allocator, try aws_sdk.globCSources(b, dependency, "source/external/libcbor/cbor/internal"));

    addPrivateSettings(context, module, dependency, config_header);
    module.addCSourceFiles(.{
        .root = dependency.path(""),
        .files = sources.items,
        .flags = commonFlags(context),
    });

    // AWS_HAVE_AVX2_INTRINSICS: the SIMD base64 decoder, compiled with -mavx -mavx2 (simd_append_source_and_features).
    if (extensions and context.isX86_64) {
        module.addCMacro("USE_SIMD_ENCODING", "1");
        const avx2 = context.createLibraryForTarget("aws-c-common-avx2", context.targetWithFeatures(&.{
            @intFromEnum(std.Target.x86.Feature.avx),
            @intFromEnum(std.Target.x86.Feature.avx2),
        }));
        addPrivateSettings(context, avx2.root_module, dependency, config_header);
        avx2.root_module.addCMacro("USE_SIMD_ENCODING", "1");
        avx2.root_module.addCSourceFiles(.{
            .root = dependency.path(""),
            .files = &.{"source/arch/intel/encoding_avx2.c"},
            .flags = commonFlags(context),
        });
        module.linkLibrary(avx2);
    }

    if (context.isWindows) {
        for ([_][]const u8{ "bcrypt", "kernel32", "ws2_32", "shlwapi", "psapi" }) |system_library| {
            module.linkSystemLibrary(system_library, .{});
        }
    }
    else if (context.isMacos) {
        // PLATFORM_LIBS dl Threads::Threads "-framework CoreFoundation" (PUBLIC). Threads::Threads is empty on macOS,
        // whose C library has the pthread functions.
        module.linkSystemLibrary("dl", .{});
        module.linkFramework("CoreFoundation", .{});
    }
    else {
        for ([_][]const u8{ "dl", "m", "pthread", "rt" }) |system_library| {
            module.linkSystemLibrary(system_library, .{});
        }
    }

    library.installHeadersDirectory(dependency.path("include"), "", .{ .include_extensions = &.{ ".h", ".inl" } });
    library.installConfigHeader(config_header);
    return library;
}

//
// Adds the include paths and private defines of aws-c-common's sources.
//
fn addPrivateSettings(context: *const aws_sdk.Context, module: *std.Build.Module, dependency: *std.Build.Dependency, config_header: *std.Build.Step.ConfigHeader) void {
    module.addIncludePath(dependency.path("source/external/libcbor"));
    module.addIncludePath(dependency.path("include"));
    module.addConfigHeader(config_header);
    addCommonDefines(context, module);
    module.addCMacro("CJSON_HIDE_SYMBOLS", "1");
    if (context.isWindows) {
        module.addCMacro("WINDOWS_KERNEL_LIB", "kernel32");
        module.addCMacro("PSAPI_VERSION", "1");
        // AwsThreadAffinity.cmake: not UNIX.
        module.addCMacro("AWS_AFFINITY_METHOD", "AWS_AFFINITY_METHOD_NONE");
    }
    else if (context.isMacos) {
        // _POSIX_C_SOURCE and _XOPEN_SOURCE are not defined on Apple (the CMake file's comment: they would revert the
        // headers to an older version).
        // AwsThreadAffinity.cmake: Apple platforms do not support thread affinity.
        module.addCMacro("AWS_AFFINITY_METHOD", "AWS_AFFINITY_METHOD_NONE");
        // AwsThreadName.cmake: the setter is not probed on Apple (the thread code uses its 1 argument version there);
        // macOS's pthread_getname_np takes 3 arguments.
        module.addCMacro("AWS_PTHREAD_GETNAME_TAKES_3ARGS", "1");
    }
    else {
        module.addCMacro("_POSIX_C_SOURCE", "200809L");
        module.addCMacro("_XOPEN_SOURCE", "500");
        // AwsThreadAffinity.cmake: pthread_attr_setaffinity_np exists in glibc; musl only has pthread_setaffinity_np.
        if (context.isMusl) {
            module.addCMacro("AWS_AFFINITY_METHOD", "AWS_AFFINITY_METHOD_PTHREAD");
        }
        else {
            module.addCMacro("AWS_AFFINITY_METHOD", "AWS_AFFINITY_METHOD_PTHREAD_ATTR");
        }
        // AwsThreadName.cmake: glibc's pthread_setname_np takes 2 arguments and pthread_getname_np 3.
        module.addCMacro("AWS_PTHREAD_SETNAME_TAKES_2ARGS", "1");
        module.addCMacro("AWS_PTHREAD_GETNAME_TAKES_3ARGS", "1");
    }
}
