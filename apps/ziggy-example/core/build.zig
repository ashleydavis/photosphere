const std = @import("std");
const ziggy_core_build = @import("ziggy-core");

//
// The name of the module exposed by this package.
//
const module_name = "ziggy-example-core";

//
// Builds the example's core as a static library (libziggy_example.a, with ziggy.h installed beside it) and, for
// Android, a shared library, plus a test step that runs every file in src/test. The built page (apps/ziggy-example/dist,
// made by `bun run bundle:ui`) is embedded in the library for the shells that ask the core for each file of the page.
// The test-hooks option compiles in the test control connection and is never set for a release.
//
pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const test_hooks = b.option(bool, "test-hooks", "Compile in the test hooks (the test control connection)") orelse false;

    const ziggy_core = b.dependency("ziggy-core", .{
        .target = target,
        .optimize = optimize,
        .@"test-hooks" = test_hooks,
    });

    const handlers_module = b.addModule(module_name, .{
        .root_source_file = b.path("src/index.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    handlers_module.addImport("ziggy-core", ziggy_core.module("ziggy-core"));
    handlers_module.addImport("page-files", try ziggy_core_build.embedPage(b, ziggy_core.module("ziggy-core"), "ziggy-core", "../dist"));

    const static_library = b.addLibrary(.{
        .name = "ziggy_example",
        .root_module = handlers_module,
        .linkage = .static,
    });
    // The Xcode linker is not Zig's, so the compiler runtime (for example ___zig_probe_stack) must travel inside the archive.
    static_library.bundle_compiler_rt = true;
    b.installArtifact(static_library);
    b.getInstallStep().dependOn(&b.addInstallFileWithDir(ziggy_core.path("src/lib/ziggy.h"), .header, "ziggy.h").step);

    if (target.result.abi.isAndroid()) {
        const shared_module = b.createModule(.{
            .root_source_file = b.path("src/index.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        shared_module.addImport("ziggy-core", ziggy_core.module("ziggy-core"));
        shared_module.addImport("page-files", try ziggy_core_build.embedPage(b, ziggy_core.module("ziggy-core"), "ziggy-core", "../dist"));
        const shared_library = b.addLibrary(.{
            .name = "ziggy_example",
            .root_module = shared_module,
            .linkage = .dynamic,
        });
        // Android 15 and later can run with 16 KiB memory pages, and a library is loaded only when its segments are
        // aligned to the page size, so they are aligned to the larger one.
        shared_library.link_z_max_page_size = 16384;
        b.installArtifact(shared_library);
    }

    const test_step = b.step("test", "Run unit tests");
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
        try test_root_source.appendSlice(b.allocator, b.fmt("    _ = @import(\"{s}\");\n", .{entry.path}));
    }
    try test_root_source.appendSlice(b.allocator, "}\n");
    const test_core = b.dependency("ziggy-core", .{
        .target = target,
        .optimize = optimize,
        .@"test-hooks" = true,
    });
    const test_module = b.createModule(.{
        .root_source_file = test_files.add("src/test/all-tests.zig", test_root_source.items),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const example_for_tests = b.createModule(.{
        .root_source_file = b.path("src/handlers.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    example_for_tests.addImport("ziggy-core", test_core.module("ziggy-core"));
    example_for_tests.addImport("page-files", try ziggy_core_build.embedPage(b, test_core.module("ziggy-core"), "ziggy-core", "../dist"));
    test_module.addImport("ziggy-core", test_core.module("ziggy-core"));
    test_module.addImport(module_name, example_for_tests);
    const unit_test = b.addTest(.{ .root_module = test_module });
    const run_test = b.addRunArtifact(unit_test);
    run_test.setCwd(b.path("."));
    test_step.dependOn(&run_test.step);
}
