const std = @import("std");
const aws_sdk = @import("aws-sdk.zig");
const aws_c_common = @import("aws-c-common.zig");
const aws_c_io = @import("aws-c-io.zig");

//
// Builds aws-c-auth as its CMakeLists.txt does (BUILD_RELOCATABLE_BINARIES off).
//

//
// Builds aws-c-auth.
//
pub fn build(context: *const aws_sdk.Context, dependency: *std.Build.Dependency, sdkutils: *std.Build.Step.Compile, cal: *std.Build.Step.Compile, http: *std.Build.Step.Compile) !*std.Build.Step.Compile {
    const library = aws_c_common.createLibrary(context, "aws-c-auth");
    const module = library.root_module;
    module.addIncludePath(dependency.path("include"));
    module.linkLibrary(sdkutils);
    module.linkLibrary(cal);
    module.linkLibrary(http);
    aws_c_common.addCommonDefines(context, module);
    aws_c_io.addPublicDefines(context, module);
    module.addCMacro("CJSON_HIDE_SYMBOLS", "1");
    module.addCSourceFiles(.{
        .root = dependency.path(""),
        .files = try aws_sdk.globCSources(context.b, dependency, "source"),
        .flags = aws_c_common.commonFlags(context),
    });
    library.installHeadersDirectory(dependency.path("include"), "", .{ .include_extensions = &.{ ".h", ".inl" } });
    // The headers of the PUBLIC link libraries, which CMake passes on to everything that links this one.
    library.installLibraryHeaders(sdkutils);
    library.installLibraryHeaders(cal);
    library.installLibraryHeaders(http);
    return library;
}
