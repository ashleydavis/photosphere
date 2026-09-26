const std = @import("std");
const aws_sdk = @import("aws-sdk.zig");
const aws_c_common = @import("aws-c-common.zig");

//
// Builds aws-checksums as its CMakeLists.txt does. The hardware-accelerated files are compiled with the CPU features
// of their per-file flags (simd_append_source_and_features in aws-c-common's AwsSIMD.cmake).
//

//
// The x86 features of AwsSIMD.cmake's flag variables.
//
const x86 = std.Target.x86.Feature;

//
// Compiles files of aws-checksums into their own library with extra CPU features and links it into aws-checksums.
//
fn addAcceleratedSources(context: *const aws_sdk.Context, library: *std.Build.Step.Compile, dependency: *std.Build.Dependency, common: *std.Build.Step.Compile, name: []const u8, features: []const std.Target.Cpu.Feature.Set.Index, files: []const []const u8) void {
    const accelerated = context.createLibraryForTarget(name, context.targetWithFeatures(features));
    addPrivateSettings(context, accelerated.root_module, dependency, common);
    accelerated.root_module.addCSourceFiles(.{
        .root = dependency.path(""),
        .files = files,
        .flags = aws_c_common.commonFlags(context),
    });
    library.root_module.linkLibrary(accelerated);
}

//
// Adds the include paths and defines of aws-checksums' sources.
//
fn addPrivateSettings(context: *const aws_sdk.Context, module: *std.Build.Module, dependency: *std.Build.Dependency, common: *std.Build.Step.Compile) void {
    module.addIncludePath(dependency.path("include"));
    module.linkLibrary(common);
    aws_c_common.addCommonDefines(context, module);
}

//
// Builds aws-checksums.
//
pub fn build(context: *const aws_sdk.Context, dependency: *std.Build.Dependency, common: *std.Build.Step.Compile) !*std.Build.Step.Compile {
    const b = context.b;
    const library = aws_c_common.createLibrary(context, "aws-checksums");
    addPrivateSettings(context, library.root_module, dependency, common);
    library.root_module.addCSourceFiles(.{
        .root = dependency.path(""),
        .files = try aws_sdk.globCSources(b, dependency, "source"),
        .flags = aws_c_common.commonFlags(context),
    });

    if (aws_c_common.useCpuExtensions(context) and context.isX86_64) {
        // AWS_HAVE_GCC_INLINE_ASM: ${AWS_SSE4_2_FLAG}.
        addAcceleratedSources(context, library, dependency, common, "aws-checksums-sse42-asm", &.{@intFromEnum(x86.sse4_2)}, &.{"source/intel/asm/crc32c_sse42_asm.c"});
        // AWS_HAVE_AVX512_INTRINSICS: ${AWS_AVX512_FLAG} ${AWS_AVX512vL_FLAG} ${AWS_AVX2_FLAG} ${AWS_CLMUL_FLAG} ${AWS_SSE4_2_FLAG}.
        addAcceleratedSources(context, library, dependency, common, "aws-checksums-crc64-avx512", &.{
            @intFromEnum(x86.avx512f),
            @intFromEnum(x86.vpclmulqdq),
            @intFromEnum(x86.avx512vl),
            @intFromEnum(x86.avx),
            @intFromEnum(x86.avx2),
            @intFromEnum(x86.pclmul),
            @intFromEnum(x86.sse4_2),
        }, &.{"source/intel/intrin/crc64nvme_avx512.c"});
        // UBER_FILE_FLAGS: the AVX-512 flags (AWS_HAVE_AVX512_INTRINSICS), ${AWS_CLMUL_FLAG} (AWS_HAVE_CLMUL) and ${AWS_SSE4_2_FLAG}.
        addAcceleratedSources(context, library, dependency, common, "aws-checksums-crc32c-avx512", &.{
            @intFromEnum(x86.avx512f),
            @intFromEnum(x86.vpclmulqdq),
            @intFromEnum(x86.avx512vl),
            @intFromEnum(x86.avx),
            @intFromEnum(x86.avx2),
            @intFromEnum(x86.pclmul),
            @intFromEnum(x86.sse4_2),
        }, &.{"source/intel/intrin/crc32c_sse42_avx512.c"});
        // AWS_HAVE_CLMUL: ${AWS_AVX2_FLAG} ${AWS_CLMUL_FLAG} ${AWS_SSE4_2_FLAG}.
        addAcceleratedSources(context, library, dependency, common, "aws-checksums-crc64-clmul", &.{
            @intFromEnum(x86.avx),
            @intFromEnum(x86.avx2),
            @intFromEnum(x86.pclmul),
            @intFromEnum(x86.sse4_2),
        }, &.{"source/intel/intrin/crc64nvme_clmul.c"});
    }
    else if (aws_c_common.useCpuExtensions(context) and context.isAarch64) {
        // ${AWS_ARMv8_1_FLAG}: -march=armv8-a+crc+crypto (the -mtune it may add only affects scheduling).
        addAcceleratedSources(context, library, dependency, common, "aws-checksums-arm", &.{
            @intFromEnum(std.Target.aarch64.Feature.crc),
            @intFromEnum(std.Target.aarch64.Feature.crypto),
            @intFromEnum(std.Target.aarch64.Feature.outline_atomics),
        }, &.{ "source/arm/crc32c_arm.c", "source/arm/crc64_arm.c" });
    }

    library.installHeadersDirectory(dependency.path("include"), "", .{ .include_extensions = &.{ ".h", ".inl" } });
    // The headers of the PUBLIC link libraries, which CMake passes on to everything that links this one.
    library.installLibraryHeaders(common);
    return library;
}
