const std = @import("std");
const imagemagick = @import("imagemagick.zig");
const zlib_ng = @import("zlib").zlib_ng;

//
// Builds ImageMagick with its delegates (libjpeg, libpng, libwebp and lcms2) for the target, over the zlib-ng of third-party/zlib-ng, and
// installs them under zig-out/<arch>-<os>-<abi>: the static libraries in lib and MagickWand.h translated to Zig as zig/magick.zig.
// zlib-ng is not installed here: Photosphere's build links the one third-party/zlib-ng installs.
//
pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});

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
    installBuildComplete(b, directory);
}

//
// Installs zig-out/<directory>/build-complete after everything else the install step installs. Photosphere's build runs this build
// when that file is missing, so a build that was killed part way through is finished rather than linked from.
//
fn installBuildComplete(b: *std.Build, directory: []const u8) void {
    const install_steps = b.getInstallStep().dependencies.items;
    std.debug.assert(install_steps.len > 0);
    const build_complete = b.addWriteFiles().add("build-complete", "Every library of this build is installed in this directory.\n");
    const install_build_complete = b.addInstallFileWithDir(build_complete, .{
        .custom = directory,
    }, "build-complete");
    for (install_steps) |install_step| {
        install_build_complete.step.dependOn(install_step);
    }
    b.getInstallStep().dependOn(&install_build_complete.step);
    std.debug.assert(b.getInstallStep().dependencies.items.len == install_steps.len + 1);
}
