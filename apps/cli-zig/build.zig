const std = @import("std");

//
// The name of the module exposed by this package.
//
const module_name = "cli-zig";

//
// Names of the packages this package depends on.
//
const dependency_names = [_][]const u8{
    "utils-zig",
    "node-utils-zig",
    "tools-zig",
    "encryption-zig",
    "storage-zig",
    "vault-zig",
    "fuzzy-match-zig",
    "task-queue-zig",
    "serialization-zig",
    "merkle-tree-zig",
    "bdb-zig",
    "api-zig",
    "node-api-zig",
    "lan-share-core-zig",
    "lan-share-network-zig",
};

//
// Builds the module, the `psi` executable (installed to zig-out/bin/psi) and registers a test step
// that runs every file in src/test.
// The default optimize mode is ReleaseSafe because RSA key generation is too slow in Debug.
//
pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.option(std.builtin.OptimizeMode, "optimize", "Prioritize performance, safety, or binary size (default: ReleaseSafe)") orelse .ReleaseSafe;

    const module = b.addModule(module_name, .{
        .root_source_file = b.path("index.zig"),
        .target = target,
        .optimize = optimize,
    });
    for (dependency_names) |dependency_name| {
        const dependency = b.dependency(dependency_name, .{ .target = target, .optimize = optimize });
        module.addImport(dependency_name, dependency.module(dependency_name));
    }

    const executable = b.addExecutable(.{
        .name = "psi",
        .root_module = module,
    });
    b.installArtifact(executable);

    const test_file = b.option([]const u8, "test-file", "Only run the tests of this file (e.g. prompts.test.zig)");
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(b.getInstallStep());
    // Every test file is compiled into one test program, whose root imports each of them. Compiled one
    // program per file, the whole CLI was compiled in ReleaseSafe 24 times over, which was most of the
    // time the unit tests took. The test files, with test-helpers.zig beside them, are copied next to
    // the generated root so that its imports and theirs resolve as they do in src/test.
    const test_files = b.addWriteFiles();
    var test_root_source: std.ArrayList(u8) = .empty;
    try test_root_source.appendSlice(b.allocator, "test {\n");
    var test_dir = try b.build_root.handle.openDir(b.graph.io, "src/test", .{ .iterate = true });
    defer test_dir.close(b.graph.io);
    var walker = try test_dir.walk(b.allocator);
    defer walker.deinit();
    while (try walker.next(b.graph.io)) |entry| {
        if (entry.kind != .file or entry.depth() != 1 or !std.mem.endsWith(u8, entry.path, ".zig")) {
            continue;
        }
        _ = test_files.addCopyFile(b.path(b.fmt("src/test/{s}", .{entry.path})), entry.path);
        if (!std.mem.endsWith(u8, entry.path, ".test.zig")) {
            continue;
        }
        if (test_file) |only_file| {
            if (!std.mem.eql(u8, entry.path, only_file)) {
                continue;
            }
        }
        try test_root_source.appendSlice(b.allocator, b.fmt("    _ = @import(\"{s}\");\n", .{entry.path}));
    }
    try test_root_source.appendSlice(b.allocator, "}\n");
    const test_module = b.createModule(.{
        .root_source_file = test_files.add("all-tests.zig", test_root_source.items),
        .target = target,
        .optimize = optimize,
    });
    test_module.addImport(module_name, module);
    for (dependency_names) |dependency_name| {
        const dependency = b.dependency(dependency_name, .{ .target = target, .optimize = optimize });
        test_module.addImport(dependency_name, dependency.module(dependency_name));
    }
    const unit_test = b.addTest(.{ .root_module = test_module });
    const run_test = b.addRunArtifact(unit_test);
    run_test.setCwd(b.path("."));
    run_test.step.dependOn(b.getInstallStep());

    // The program the tests run CLI functions in, against the real process streams (installed to
    // zig-out/test-bin, not zig-out/bin: it is not shipped).
    const test_driver_module = b.createModule(.{
        .root_source_file = b.path("src/test/drivers/test-driver.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_driver_module.addImport(module_name, module);
    for (dependency_names) |dependency_name| {
        const dependency = b.dependency(dependency_name, .{ .target = target, .optimize = optimize });
        test_driver_module.addImport(dependency_name, dependency.module(dependency_name));
    }
    const test_driver = b.addExecutable(.{
        .name = "test-driver",
        .root_module = test_driver_module,
    });
    const install_test_driver = b.addInstallArtifact(test_driver, .{ .dest_dir = .{ .override = .{ .custom = "test-bin" } } });
    run_test.step.dependOn(&install_test_driver.step);
    test_step.dependOn(&run_test.step);

    // The tests of this CLI and of every Zig package, in this one build. The packages' dependencies are
    // then built once and shared, so the AWS SDK for C compiles once instead of once in each package that
    // uses it. The packages' tests build in Debug, as they do when each package is tested on its own.
    const test_all_step = b.step("test-all", "Run the unit tests of the Zig CLI and of every Zig package");
    test_all_step.dependOn(test_step);
    for (dependency_names) |dependency_name| {
        const dependency = b.dependency(dependency_name, .{ .target = target, .optimize = .Debug });
        test_all_step.dependOn(&dependency.builder.top_level_steps.get("test").?.step);
    }

    // The storage package's integration tests against a real S3 server, built as test-all builds that package, so
    // they reuse what test-all compiled (the AWS SDK for C above all) instead of compiling it again.
    const storage_integration_step = b.step("test-storage-integration", "Run the storage package's integration tests against the S3 server the environment names");
    const storage = b.dependency("storage-zig", .{ .target = target, .optimize = .Debug });
    storage_integration_step.dependOn(&storage.builder.top_level_steps.get("test-integration").?.step);
}
