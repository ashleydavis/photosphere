const std = @import("std");
const aws_sdk = @import("aws-sdk.zig");
const aws_c_common = @import("aws-c-common.zig");
const aws_c_io = @import("aws-c-io.zig");

//
// Builds aws-c-http as its CMakeLists.txt does.
//

//
// Builds aws-c-http.
//
pub fn build(context: *const aws_sdk.Context, dependency: *std.Build.Dependency, io: *std.Build.Step.Compile, compression: *std.Build.Step.Compile) !*std.Build.Step.Compile {
    const library = aws_c_common.createLibrary(context, "aws-c-http");
    const module = library.root_module;
    module.addIncludePath(dependency.path("include"));
    module.linkLibrary(io);
    module.linkLibrary(compression);
    aws_c_common.addCommonDefines(context, module);
    aws_c_io.addPublicDefines(context, module);
    module.addCSourceFiles(.{
        .root = dependency.path(""),
        .files = try aws_sdk.globCSources(context.b, dependency, "source"),
        .flags = aws_c_common.commonFlags(context),
    });
    library.installHeadersDirectory(dependency.path("include"), "", .{ .include_extensions = &.{ ".h", ".inl" } });
    // The headers of the PUBLIC link libraries, which CMake passes on to everything that links this one.
    library.installLibraryHeaders(io);
    library.installLibraryHeaders(compression);
    return library;
}
