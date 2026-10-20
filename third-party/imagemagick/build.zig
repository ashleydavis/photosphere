const std = @import("std");
const imagemagick = @import("imagemagick.zig");
const zlib_ng = @import("zlib").zlib_ng;

//
// Builds ImageMagick with its delegates (libjpeg, libpng and libwebp) for the target, over the zlib-ng of third-party/zlib-ng, and
// installs them under zig-out/<arch>-<os>-<abi>: the static libraries in lib and MagickWand.h translated to Zig as zig/magick.zig.
// zlib-ng is not installed here: Photosphere's build links the one third-party/zlib-ng installs. `zig build test` runs the tests of
// the program that makes ImageMagick's threshold maps.
//
pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});

    const test_step = b.step("test", "Run the tests of the program that makes ImageMagick's threshold maps");
    const tests = b.addTest(.{
        .name = "threshold-map",
        .root_module = b.createModule(.{
            .root_source_file = b.path("threshold-map.test.zig"),
            .target = b.graph.host,
        }),
    });
    test_step.dependOn(&b.addRunArtifact(tests).step);

    if (imagemagick.unsupportedReason(b, target)) |reason| {
        b.getInstallStep().dependOn(&b.addFail(reason).step);
        return;
    }
    const zlib_dependency = b.dependency("zlib", .{
        .target = target,
    });
    const zlib: zlib_ng.IZlibNg = .{
        .library = zlib_dependency.artifact("z"),
        .include_directory = zlib_dependency.namedLazyPath("include"),
    };
    const library = try imagemagick.buildImageMagick(b, target, zlib);
    const directory = b.fmt("{s}-{s}-{s}", .{ @tagName(target.result.cpu.arch), @tagName(target.result.os.tag), @tagName(target.result.abi) });

    // ImageMagick and every static library it links in turn but zlib-ng's: a static library does not hold the ones it links, so each
    // is installed for Photosphere's build to link.
    var installed = std.AutoHashMap(*std.Build.Step.Compile, void).init(b.allocator);
    for (zlib.library.getCompileDependencies(true)) |zlib_library| {
        try installed.put(zlib_library, {});
    }
    for (library.library.getCompileDependencies(true)) |dependency| {
        if (dependency.kind != .lib or dependency.linkage != .static or installed.contains(dependency)) {
            continue;
        }
        try installed.put(dependency, {});
        b.getInstallStep().dependOn(&b.addInstallArtifact(dependency, .{
            .dest_dir = .{
                .override = .{
                    .custom = b.fmt("{s}/lib", .{directory}),
                },
            },
            .h_dir = .disabled,
        }).step);
    }
    const module = try imagemagick.translateHeaders(b, target, library);
    b.getInstallStep().dependOn(&b.addInstallFileWithDir(module.root_source_file.?, .{
        .custom = b.fmt("{s}/zig", .{directory}),
    }, "magick.zig").step);
}
