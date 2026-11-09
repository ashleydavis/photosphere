const std = @import("std");
const ffmpeg = @import("ffmpeg.zig");
const zlib_ng = @import("zlib").zlib_ng;

//
// Builds FFmpeg (its libraries, with the ffmpeg and ffprobe programs compiled in) for the target, over the zlib-ng of
// third-party/zlib-ng, and installs it under zig-out/<arch>-<os>-<abi>/lib. zlib-ng is not installed here: Photosphere's build links
// the one third-party/zlib-ng installs.
//
pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    if (ffmpeg.unsupportedReason(b, target)) |reason| {
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
    const library = try ffmpeg.buildFfmpeg(b, target, zlib);
    const directory = b.fmt("{s}-{s}-{s}", .{ @tagName(target.result.cpu.arch), @tagName(target.result.os.tag), @tagName(target.result.abi) });

    // FFmpeg and every static library it links in turn but zlib-ng's: a static library does not hold the ones it links, so each is
    // installed for Photosphere's build to link.
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
}
