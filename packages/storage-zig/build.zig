const std = @import("std");
const aws_sdk = @import("aws/aws-sdk.zig");

//
// The name of the module exposed by this package.
//
const module_name = "storage-zig";

//
// Names of the packages this package depends on.
//
const dependency_names = [_][]const u8{ "utils-zig", "node-utils-zig", "encryption-zig" };

//
// Builds the module and registers a test step that runs every file in src/test.
//
pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const module = b.addModule(module_name, .{
        .root_source_file = b.path("src/index.zig"),
        .target = target,
        .optimize = optimize,
    });
    for (dependency_names) |dependency_name| {
        const dependency = b.dependency(dependency_name, .{ .target = target, .optimize = optimize });
        module.addImport(dependency_name, dependency.module(dependency_name));
    }
    // The AWS SDK for C, which the S3 client binds to. False means a lazy dependency is being fetched first.
    if (!try aws_sdk.addAwsSdk(b, module, target)) {
        return;
    }

    const test_step = b.step("test", "Run unit tests");
    var test_dir = try b.build_root.handle.openDir(b.graph.io, "src/test", .{ .iterate = true });
    defer test_dir.close(b.graph.io);
    var walker = try test_dir.walk(b.allocator);
    defer walker.deinit();
    while (try walker.next(b.graph.io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.path, ".test.zig")) {
            continue;
        }
        const test_module = b.createModule(.{
            .root_source_file = b.path(b.fmt("src/test/{s}", .{entry.path})),
            .target = target,
            .optimize = optimize,
        });
        test_module.addImport(module_name, module);
        test_module.addImport(aws_sdk.aws_c_module_name, module.import_table.get(aws_sdk.aws_c_module_name).?);
        for (dependency_names) |dependency_name| {
            const dependency = b.dependency(dependency_name, .{ .target = target, .optimize = optimize });
            test_module.addImport(dependency_name, dependency.module(dependency_name));
        }
        const unit_test = b.addTest(.{ .root_module = test_module });
        const run_test = b.addRunArtifact(unit_test);
        run_test.setCwd(b.path("."));
        test_step.dependOn(&run_test.step);
    }
}
