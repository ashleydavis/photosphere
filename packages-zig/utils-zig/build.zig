const std = @import("std");

//
// The name of the module exposed by this package.
//
const module_name = "utils-zig";

//
// Names of the packages this package depends on.
//
const dependency_names = [_][]const u8{};

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

    const test_file = b.option([]const u8, "test-file", "Only run the tests of this file (e.g. batch-generator.test.zig)");
    const test_step = b.step("test", "Run unit tests");
    // Every test file is compiled into one test program, whose root imports each of them. Compiled one program
    // per file, each linked the package and everything it depends on again, which was most of the time the unit
    // tests took (past the CI timeout on Windows). The src directory is copied next to the generated root so that
    // the imports and embedded files of the tests resolve as they do in src/test.
    const test_files = b.addWriteFiles();
    _ = test_files.addCopyDirectory(b.path("src"), "src", .{});
    var test_root_source: std.ArrayList(u8) = .empty;
    try test_root_source.appendSlice(b.allocator, "test {\n");
    var test_dir = try b.build_root.handle.openDir(b.graph.io, "src/test", .{ .iterate = true });
    defer test_dir.close(b.graph.io);
    var walker = try test_dir.walk(b.allocator);
    defer walker.deinit();
    while (try walker.next(b.graph.io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.path, ".test.zig")) {
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
        .root_source_file = test_files.add("src/test/all-tests.zig", test_root_source.items),
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
    test_step.dependOn(&run_test.step);
}
