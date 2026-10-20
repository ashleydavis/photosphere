const std = @import("std");
const aws_lc = @import("aws-lc.zig");
const aws_sdk = @import("aws-sdk.zig");

//
// Builds the AWS SDK for C and aws-lc for the target and installs them under zig-out/<arch>-<os>-<abi>: every static library in lib,
// their headers in include, and the SDK's headers translated to Zig as zig/aws-c.zig. Photosphere's build links the libraries from
// there and does not build them itself. See docs/aws-sdk.md.
//
pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const crypto = try aws_lc.build(b, target, b.dependency("aws-lc", .{}));
    const ssl = try aws_lc.buildSsl(b, target, b.dependency("aws-lc", .{}), crypto);
    // Null means a lazy dependency is being fetched first: the build runs again once it has been.
    const aws_c = (try aws_sdk.build(b, target, crypto)) orelse return;
    const directory = b.fmt("{s}-{s}-{s}", .{ @tagName(target.result.cpu.arch), @tagName(target.result.os.tag), @tagName(target.result.abi) });

    // The libraries the "aws-c" module links, and libssl, with every static library each of them links in turn: a static library does
    // not hold the ones it links, so each is installed for Photosphere's build to link.
    var roots: std.ArrayList(*std.Build.Step.Compile) = .empty;
    try roots.append(b.allocator, ssl);
    for (aws_c.link_objects.items) |link_object| {
        switch (link_object) {
            .other_step => |library| {
                try roots.append(b.allocator, library);
            },
            else => {},
        }
    }
    var installed = std.AutoHashMap(*std.Build.Step.Compile, void).init(b.allocator);
    for (roots.items) |root| {
        for (root.getCompileDependencies(true)) |library| {
            if (library.kind != .lib or library.linkage != .static or installed.contains(library)) {
                continue;
            }
            try installed.put(library, {});
            b.getInstallStep().dependOn(&b.addInstallArtifact(library, .{
                .dest_dir = .{
                    .override = .{
                        .custom = b.fmt("{s}/lib", .{directory}),
                    },
                },
                .h_dir = .{
                    .override = .{
                        .custom = b.fmt("{s}/include", .{directory}),
                    },
                },
            }).step);
        }
    }
    b.getInstallStep().dependOn(&b.addInstallFileWithDir(aws_c.root_source_file.?, .{
        .custom = b.fmt("{s}/zig", .{directory}),
    }, "aws-c.zig").step);
}
