const std = @import("std");

//
// The name of the module exposed by this package.
//
const module_name = "ziggy-core";

//
// Builds the module and registers a test step that runs every file in src/test.
// The test-hooks option compiles in the test control connection. It is off by default and never set for a release.
//
pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const test_hooks = b.option(bool, "test-hooks", "Compile in the test hooks (the test control connection)") orelse false;

    const options = b.addOptions();
    options.addOption(bool, "test_hooks", test_hooks);

    const module = b.addModule(module_name, .{
        .root_source_file = b.path("src/index.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    module.addOptions("build_options", options);

    // The Android shell reaches the core through JNI, written in Zig against the NDK's own jni.h. Only an Android target
    // has that header, so the import exists only for one.
    if (target.result.abi.isAndroid()) {
        const jni_translate_c = b.addTranslateC(.{
            .root_source_file = b.path("src/lib/jni-c.h"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        // Zig has no C library headers for Android. They come from the NDK, through the libc file the build is given with
        // --libc, and the translation step is not given that file, so its include directories are read out of it here.
        const libc_file_path = b.libc_file orelse {
            std.debug.print("An Android build needs the NDK's C library, as a libc file: pass --libc <file>.\n", .{});
            return error.LibcFileMissing;
        };
        const libc_file_text = try std.Io.Dir.cwd().readFileAlloc(b.graph.io, libc_file_path, b.allocator, .limited(64 * 1024));
        var libc_lines = std.mem.splitScalar(u8, libc_file_text, '\n');
        while (libc_lines.next()) |line| {
            for ([_][]const u8{ "include_dir=", "sys_include_dir=" }) |key| {
                if (std.mem.startsWith(u8, line, key) and line.len > key.len) {
                    jni_translate_c.addSystemIncludePath(.{ .cwd_relative = line[key.len..] });
                }
            }
        }
        module.addImport("jni-c", jni_translate_c.createModule());
    }

    const test_step = b.step("test", "Run unit tests");
    // Every test file is compiled into one test program, whose root imports each of them.
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
    const test_options = b.addOptions();
    test_options.addOption(bool, "test_hooks", true);
    const test_module = b.createModule(.{
        .root_source_file = test_files.add("src/test/all-tests.zig", test_root_source.items),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const test_core_module = b.createModule(.{
        .root_source_file = b.path("src/index.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    test_core_module.addOptions("build_options", test_options);
    test_module.addImport(module_name, test_core_module);
    const unit_test = b.addTest(.{ .root_module = test_module });
    const run_test = b.addRunArtifact(unit_test);
    run_test.setCwd(b.path("."));
    test_step.dependOn(&run_test.step);
}
