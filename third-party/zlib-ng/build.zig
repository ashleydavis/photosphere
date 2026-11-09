const std = @import("std");

//
// zlib-ng's build, which the builds of ImageMagick and FFmpeg import for the type of the zlib they are built over.
//
pub const zlib_ng = @import("zlib-ng.zig");

//
// Builds zlib-ng for the target and installs it under zig-out/<arch>-<os>-<abi>: the static library in lib, zlib.h and zconf.h in
// include, and zlib.h translated to Zig as zig/zlib.zig. Photosphere's build links the library from there and does not build it
// itself. The builds of ImageMagick and FFmpeg take this package as a dependency, for zlib.h, and build the library over it.
//
pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const zlib = try zlib_ng.buildZlibNg(b, target);
    const directory = b.fmt("{s}-{s}-{s}", .{ @tagName(target.result.cpu.arch), @tagName(target.result.os.tag), @tagName(target.result.abi) });
    // zlib-ng and the static libraries it links in turn (the parts compiled for particular CPU features): a static library does not
    // hold the ones it links, so each is installed for Photosphere's build to link.
    for (zlib.library.getCompileDependencies(true)) |library| {
        if (library.kind != .lib or library.linkage != .static) {
            continue;
        }
        b.getInstallStep().dependOn(&b.addInstallArtifact(library, .{
            .dest_dir = .{
                .override = .{
                    .custom = b.fmt("{s}/lib", .{directory}),
                },
            },
        }).step);
    }
    b.getInstallStep().dependOn(&b.addInstallDirectory(.{
        .source_dir = zlib.include_directory,
        .install_dir = .prefix,
        .install_subdir = b.fmt("{s}/include", .{directory}),
    }).step);
    // zlib.h and zconf.h, for the builds of ImageMagick and FFmpeg, which take this package as a dependency.
    b.addNamedLazyPath("include", zlib.include_directory);
    const module = try zlib_ng.translateHeaders(b, target, zlib);
    b.getInstallStep().dependOn(&b.addInstallFileWithDir(module.root_source_file.?, .{
        .custom = b.fmt("{s}/zig", .{directory}),
    }, "zlib.zig").step);
}
