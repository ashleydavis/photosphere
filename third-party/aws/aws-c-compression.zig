const std = @import("std");
const aws_sdk = @import("aws-sdk.zig");
const aws_c_common = @import("aws-c-common.zig");

//
// Builds aws-c-compression as its CMakeLists.txt does (BUILD_HUFFMAN_GENERATOR off).
//

//
// Builds aws-c-compression.
//
pub fn build(context: *const aws_sdk.Context, dependency: *std.Build.Dependency, common: *std.Build.Step.Compile) !*std.Build.Step.Compile {
    const library = aws_c_common.createLibrary(context, "aws-c-compression");
    const module = library.root_module;
    module.addIncludePath(dependency.path("include"));
    module.linkLibrary(common);
    aws_c_common.addCommonDefines(context, module);
    module.addCSourceFiles(.{
        .root = dependency.path(""),
        .files = try aws_sdk.globCSources(context.b, dependency, "source"),
        .flags = aws_c_common.commonFlags(context),
    });
    library.installHeadersDirectory(dependency.path("include"), "", .{ .include_extensions = &.{ ".h", ".inl" } });
    // The headers of the PUBLIC link libraries, which CMake passes on to everything that links this one.
    library.installLibraryHeaders(common);
    return library;
}
