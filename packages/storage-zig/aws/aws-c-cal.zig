const std = @import("std");
const aws_sdk = @import("aws-sdk.zig");
const aws_c_common = @import("aws-c-common.zig");

//
// Builds aws-c-cal as its CMakeLists.txt does (BYO_CRYPTO, USE_OPENSSL and AWS_USE_LIBCRYPTO_TO_SUPPORT_ED25519_EVERYWHERE
// off): on Linux over aws-lc's libcrypto, on Windows over the operating system's BCrypt and NCrypt, on macOS over
// CommonCrypto and the Security framework.
//

//
// Builds aws-c-cal (crypto is aws-lc's libcrypto on Linux and macOS, where only Linux uses it, and null on Windows).
//
pub fn build(context: *const aws_sdk.Context, dependency: *std.Build.Dependency, common: *std.Build.Step.Compile, crypto: ?*std.Build.Step.Compile) !*std.Build.Step.Compile {
    const b = context.b;
    const library = aws_c_common.createLibrary(context, "aws-c-cal");
    const module = library.root_module;

    var sources: std.ArrayList([]const u8) = .empty;
    try sources.appendSlice(b.allocator, try aws_sdk.globCSources(b, dependency, "source"));
    if (context.isWindows) {
        try sources.appendSlice(b.allocator, try aws_sdk.globCSources(b, dependency, "source/windows"));
        try sources.append(b.allocator, "source/shared/ed25519_noop.c");
        try sources.append(b.allocator, "source/shared/ref_hkdf.c");
        // AWS_SUPPORT_WIN7 is off.
        module.linkSystemLibrary("ncrypt", .{});
    }
    else if (context.isMacos) {
        try sources.appendSlice(b.allocator, try aws_sdk.globCSources(b, dependency, "source/darwin"));
        try sources.append(b.allocator, "source/shared/ed25519_noop.c");
        try sources.append(b.allocator, "source/shared/ref_hkdf.c");
        // PLATFORM_LIBS "-framework Security -framework CoreFoundation" (PUBLIC).
        module.linkFramework("Security", .{});
        module.linkFramework("CoreFoundation", .{});
    }
    else {
        try sources.appendSlice(b.allocator, try aws_sdk.globCSources(b, dependency, "source/unix"));
        try sources.append(b.allocator, "source/shared/ed25519.c");
        try sources.append(b.allocator, "source/shared/lccrypto_common.c");
        try sources.append(b.allocator, "source/shared/ref_hkdf.c");
        module.linkLibrary(crypto.?);
    }

    module.addIncludePath(dependency.path("include"));
    module.linkLibrary(common);
    aws_c_common.addCommonDefines(context, module);
    module.addCSourceFiles(.{
        .root = dependency.path(""),
        .files = sources.items,
        .flags = aws_c_common.commonFlags(context),
    });

    library.installHeadersDirectory(dependency.path("include"), "", .{ .include_extensions = &.{ ".h", ".inl" } });
    // The headers of the PUBLIC link libraries, which CMake passes on to everything that links this one.
    library.installLibraryHeaders(common);
    if (context.isLinux) {
        library.installLibraryHeaders(crypto.?);
    }
    return library;
}
