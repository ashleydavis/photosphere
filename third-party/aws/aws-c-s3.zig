const std = @import("std");
const aws_sdk = @import("aws-sdk.zig");
const aws_c_common = @import("aws-c-common.zig");
const aws_c_io = @import("aws-c-io.zig");

//
// Builds aws-c-s3 as its CMakeLists.txt does, with its AWS_ENABLE_S3_ENDPOINT_RESOLVER option on: the binding resolves
// endpoints with the S3 endpoint rules (aws_s3_endpoint_resolver_new), like the JavaScript SDK does.
//

//
// Builds aws-c-s3.
//
pub fn build(context: *const aws_sdk.Context, dependency: *std.Build.Dependency, auth: *std.Build.Step.Compile, checksums: *std.Build.Step.Compile) !*std.Build.Step.Compile {
    const b = context.b;
    const library = aws_c_common.createLibrary(context, "aws-c-s3");
    const module = library.root_module;
    var sources: std.ArrayList([]const u8) = .empty;
    try sources.appendSlice(b.allocator, try aws_sdk.globCSources(b, dependency, "source"));
    try sources.appendSlice(b.allocator, try aws_sdk.globCSources(b, dependency, "source/s3_endpoint_resolver"));
    module.addIncludePath(dependency.path("include"));
    module.linkLibrary(auth);
    module.linkLibrary(checksums);
    aws_c_common.addCommonDefines(context, module);
    aws_c_io.addPublicDefines(context, module);
    module.addCMacro("CJSON_HIDE_SYMBOLS", "1");
    module.addCMacro("AWS_ENABLE_S3_ENDPOINT_RESOLVER", "1");
    module.addCSourceFiles(.{
        .root = dependency.path(""),
        .files = sources.items,
        .flags = aws_c_common.commonFlags(context),
    });
    library.installHeadersDirectory(dependency.path("include"), "", .{ .include_extensions = &.{ ".h", ".inl" } });
    // The headers of the PUBLIC link libraries, which CMake passes on to everything that links this one.
    library.installLibraryHeaders(auth);
    library.installLibraryHeaders(checksums);
    return library;
}
