const std = @import("std");
const aws_sdk = @import("aws-sdk.zig");

//
// Builds s2n-tls as its CMakeLists.txt does for a Release build (S2N_INTERN_LIBCRYPTO, S2N_LTO, S2N_FUZZ_TEST and the
// sanitizers off; S2N_STACKTRACE on), over aws-lc's libcrypto.
//

//
// The results of s2n-tls' feature probes (tests/features/*.c, compiled against aws-lc's headers with the flags in the
// .flags file next to each probe) for Linux, as `-D<PROBE>=1` defines. They are the same for x86_64 and aarch64, glibc
// and musl, except S2N_EXECINFO_AVAILABLE, which needs glibc's execinfo.h, and
// S2N_CPUID_AVAILABLE, which is x86 only. S2N_COMPILER_SUPPORTS_BRANCH_ALIGN is not here: Zig's compiler does not
// accept its `-Wa,-mbranches-within-32B-boundaries` flag, so the probe fails and CMake would not add it either.
//
const linux_features = [_][]const u8{
    "S2N_ATOMIC_SUPPORTED",
    "S2N_CLOEXEC_SUPPORTED",
    "S2N_CLOEXEC_XOPEN_SUPPORTED",
    "S2N_CLONE_SUPPORTED",
    "S2N_DIAGNOSTICS_POP_SUPPORTED",
    "S2N_DIAGNOSTICS_PUSH_SUPPORTED",
    "S2N_FALL_THROUGH_SUPPORTED",
    "S2N_FEATURES_AVAILABLE",
    "S2N_KTLS_SUPPORTED",
    "S2N_LIBCRYPTO_SANITY_PROBE",
    "S2N_LIBCRYPTO_SUPPORTS_CUSTOM_OID",
    "S2N_LIBCRYPTO_SUPPORTS_EC_KEY_CHECK_FIPS",
    "S2N_LIBCRYPTO_SUPPORTS_EVP_AEAD_TLS",
    "S2N_LIBCRYPTO_SUPPORTS_EVP_KEM",
    "S2N_LIBCRYPTO_SUPPORTS_EVP_MD5_SHA1_HASH",
    "S2N_LIBCRYPTO_SUPPORTS_EVP_MD_CTX_SET_PKEY_CTX",
    "S2N_LIBCRYPTO_SUPPORTS_EVP_RC4",
    "S2N_LIBCRYPTO_SUPPORTS_FLAG_NO_CHECK_TIME",
    "S2N_LIBCRYPTO_SUPPORTS_GET0_CHAIN",
    "S2N_LIBCRYPTO_SUPPORTS_HKDF",
    "S2N_LIBCRYPTO_SUPPORTS_MLDSA",
    "S2N_LIBCRYPTO_SUPPORTS_MLKEM",
    "S2N_LIBCRYPTO_SUPPORTS_PRIVATE_RAND",
    "S2N_LIBCRYPTO_SUPPORTS_PUBLIC_RAND",
    "S2N_LIBCRYPTO_SUPPORTS_RSA_PSS_SIGNING",
    "S2N_LIBCRYPTO_SUPPORTS_SHAKE",
    "S2N_LIBCRYPTO_SUPPORTS_X509_STORE_LIST",
    "S2N_LINUX_SENDFILE",
};

//
// The results of the same probes for macOS, the same for x86_64 and aarch64 except S2N_CPUID_AVAILABLE (x86 only).
// macOS has execinfo.h (S2N_EXECINFO_AVAILABLE), but not glibc's features.h, clone, kTLS or Linux's sendfile.
//
const macos_features = [_][]const u8{
    "S2N_ATOMIC_SUPPORTED",
    "S2N_CLOEXEC_SUPPORTED",
    "S2N_CLOEXEC_XOPEN_SUPPORTED",
    "S2N_DIAGNOSTICS_POP_SUPPORTED",
    "S2N_DIAGNOSTICS_PUSH_SUPPORTED",
    "S2N_FALL_THROUGH_SUPPORTED",
    "S2N_LIBCRYPTO_SANITY_PROBE",
    "S2N_LIBCRYPTO_SUPPORTS_CUSTOM_OID",
    "S2N_LIBCRYPTO_SUPPORTS_EC_KEY_CHECK_FIPS",
    "S2N_LIBCRYPTO_SUPPORTS_EVP_AEAD_TLS",
    "S2N_LIBCRYPTO_SUPPORTS_EVP_KEM",
    "S2N_LIBCRYPTO_SUPPORTS_EVP_MD5_SHA1_HASH",
    "S2N_LIBCRYPTO_SUPPORTS_EVP_MD_CTX_SET_PKEY_CTX",
    "S2N_LIBCRYPTO_SUPPORTS_EVP_RC4",
    "S2N_LIBCRYPTO_SUPPORTS_FLAG_NO_CHECK_TIME",
    "S2N_LIBCRYPTO_SUPPORTS_GET0_CHAIN",
    "S2N_LIBCRYPTO_SUPPORTS_HKDF",
    "S2N_LIBCRYPTO_SUPPORTS_MLDSA",
    "S2N_LIBCRYPTO_SUPPORTS_MLKEM",
    "S2N_LIBCRYPTO_SUPPORTS_PRIVATE_RAND",
    "S2N_LIBCRYPTO_SUPPORTS_PUBLIC_RAND",
    "S2N_LIBCRYPTO_SUPPORTS_RSA_PSS_SIGNING",
    "S2N_LIBCRYPTO_SUPPORTS_SHAKE",
    "S2N_LIBCRYPTO_SUPPORTS_X509_STORE_LIST",
};

//
// Builds s2n-tls.
//
pub fn build(context: *const aws_sdk.Context, dependency: *std.Build.Dependency, crypto: *std.Build.Step.Compile) !*std.Build.Step.Compile {
    const b = context.b;
    const library = context.createLibrary("s2n");
    const module = library.root_module;

    var sources: std.ArrayList([]const u8) = .empty;
    try sources.appendSlice(b.allocator, try aws_sdk.globCSources(b, dependency, "crypto"));
    try sources.appendSlice(b.allocator, try aws_sdk.globCSources(b, dependency, "error"));
    try sources.appendSlice(b.allocator, try aws_sdk.globCSources(b, dependency, "stuffer"));
    try sources.appendSlice(b.allocator, try aws_sdk.globCSourcesRecursive(b, dependency, "tls"));
    try sources.appendSlice(b.allocator, try aws_sdk.globCSources(b, dependency, "utils"));

    const features: []const []const u8 = if (context.isMacos) &macos_features else &linux_features;
    for (features) |feature| {
        module.addCMacro(feature, "1");
    }
    if (context.isX86_64) {
        module.addCMacro("S2N_CPUID_AVAILABLE", "1");
    }
    // The S2N_STACKTRACE option is on, and stays on only where S2N_EXECINFO_AVAILABLE (glibc and macOS).
    if (!context.isMusl) {
        module.addCMacro("S2N_EXECINFO_AVAILABLE", "1");
        module.addCMacro("S2N_STACKTRACE", "1");
    }
    // CMAKE_BUILD_TYPE matches "Rel".
    module.addCMacro("S2N_BUILD_RELEASE", "1");

    module.addIncludePath(dependency.path(""));
    module.addIncludePath(dependency.path("api"));
    module.linkLibrary(crypto);
    module.addCSourceFiles(.{
        .root = dependency.path(""),
        .files = sources.items,
        .flags = &.{
            "-std=gnu99",
            "-fvisibility=hidden",
            "-DS2N_EXPORTS=1",
            "-include",
            b.pathJoin(&.{ dependency.builder.build_root.path orelse ".", "utils/s2n_prelude.h" }),
        },
    });
    // OS_LIBS and m: on Apple `c Threads::Threads` (Threads::Threads is empty on macOS, whose C library has the
    // pthread functions), elsewhere `Threads::Threads dl rt`.
    const system_libraries: []const []const u8 = if (context.isMacos) &.{ "c", "m" } else &.{ "pthread", "dl", "rt", "m" };
    for (system_libraries) |system_library| {
        module.linkSystemLibrary(system_library, .{});
    }

    // The headers of the PUBLIC link library (libcrypto).
    library.installLibraryHeaders(crypto);
    // install(FILES ${API_HEADERS} DESTINATION "include/") and ${API_UNSTABLE_HEADERS} to "include/s2n/unstable".
    for (try aws_sdk.globFiles(b, dependency, "api", ".h")) |header| {
        library.installHeader(dependency.path(header), std.fs.path.basename(header));
    }
    for (try aws_sdk.globFiles(b, dependency, "api/unstable", ".h")) |header| {
        library.installHeader(dependency.path(header), b.fmt("s2n/unstable/{s}", .{std.fs.path.basename(header)}));
    }
    return library;
}
