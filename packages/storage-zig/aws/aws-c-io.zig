const std = @import("std");
const aws_sdk = @import("aws-sdk.zig");
const aws_c_common = @import("aws-c-common.zig");

//
// Builds aws-c-io as its CMakeLists.txt does (USE_VSOCK, BYO_CRYPTO and BUILD_RELOCATABLE_BINARIES off): on Linux with
// the epoll event loop and s2n-tls, on Windows with I/O completion ports (USE_IO_COMPLETION_PORTS is on by default)
// and SChannel, on macOS with the kqueue and dispatch queue event loops (kqueue is the default one), Secure Transport
// and s2n-tls (AWS_USE_SECITEM is not defined, so USE_S2N is on by default; the TLS implementation is chosen at run
// time).
//

//
// The PUBLIC compile definitions of aws-c-io (`-DAWS_ENABLE_<event loop>`), which everything that includes its headers
// is compiled with.
//
pub fn publicDefines(context: *const aws_sdk.Context) []const []const u8 {
    if (context.isWindows) {
        return &.{"AWS_ENABLE_IO_COMPLETION_PORTS"};
    }
    // EVENT_LOOP_DEFINES on Apple: DISPATCH_QUEUE, since the Network and Security frameworks are found, then KQUEUE,
    // since the system is Darwin and AWS_USE_SECITEM is not defined.
    if (context.isMacos) {
        return &.{ "AWS_ENABLE_DISPATCH_QUEUE", "AWS_ENABLE_KQUEUE" };
    }
    return &.{"AWS_ENABLE_EPOLL"};
}

//
// Adds the PUBLIC compile definitions of aws-c-io to a module.
//
pub fn addPublicDefines(context: *const aws_sdk.Context, module: *std.Build.Module) void {
    for (publicDefines(context)) |define| {
        module.addCMacro(define, "1");
    }
}

//
// Builds aws-c-io (s2n is s2n-tls on Linux and macOS, and null on Windows).
//
pub fn build(context: *const aws_sdk.Context, dependency: *std.Build.Dependency, common: *std.Build.Step.Compile, cal: *std.Build.Step.Compile, s2n: ?*std.Build.Step.Compile) !*std.Build.Step.Compile {
    const b = context.b;
    const library = aws_c_common.createLibrary(context, "aws-c-io");
    const module = library.root_module;

    var sources: std.ArrayList([]const u8) = .empty;
    try sources.appendSlice(b.allocator, try aws_sdk.globCSources(b, dependency, "source"));
    if (context.isWindows) {
        try sources.appendSlice(b.allocator, try aws_sdk.globCSources(b, dependency, "source/windows"));
        try sources.appendSlice(b.allocator, try aws_sdk.globCSources(b, dependency, "source/windows/iocp"));
        module.linkSystemLibrary("secur32", .{});
        module.linkSystemLibrary("crypt32", .{});
    }
    else if (context.isMacos) {
        try sources.appendSlice(b.allocator, try aws_sdk.globCSources(b, dependency, "source/bsd"));
        try sources.appendSlice(b.allocator, try aws_sdk.globCSources(b, dependency, "source/posix"));
        try sources.appendSlice(b.allocator, try aws_sdk.globCSources(b, dependency, "source/darwin"));
        try sources.appendSlice(b.allocator, try aws_sdk.globCSources(b, dependency, "source/s2n"));
        module.addCMacro("USE_S2N", "1");
        module.linkLibrary(s2n.?);
        // PLATFORM_LIBS "-framework Security -framework Network" (PRIVATE).
        module.linkFramework("Security", .{});
        module.linkFramework("Network", .{});
    }
    else {
        try sources.appendSlice(b.allocator, try aws_sdk.globCSources(b, dependency, "source/linux"));
        try sources.appendSlice(b.allocator, try aws_sdk.globCSources(b, dependency, "source/posix"));
        try sources.appendSlice(b.allocator, try aws_sdk.globCSources(b, dependency, "source/s2n"));
        module.addCMacro("USE_S2N", "1");
        module.linkLibrary(s2n.?);
    }

    module.addIncludePath(dependency.path("include"));
    module.linkLibrary(common);
    module.linkLibrary(cal);
    aws_c_common.addCommonDefines(context, module);
    addPublicDefines(context, module);
    module.addCSourceFiles(.{
        .root = dependency.path(""),
        .files = sources.items,
        .flags = aws_c_common.commonFlags(context),
    });

    library.installHeadersDirectory(dependency.path("include"), "", .{ .include_extensions = &.{ ".h", ".inl" } });
    // The headers of the PUBLIC link libraries, which CMake passes on to everything that links this one.
    library.installLibraryHeaders(common);
    library.installLibraryHeaders(cal);
    if (s2n) |s2n_library| {
        library.installLibraryHeaders(s2n_library);
    }
    return library;
}
