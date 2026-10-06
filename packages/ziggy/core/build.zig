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
    module.addAnonymousImport("ziggy-inject", .{
        .root_source_file = b.path("../bridge/inject/ziggy-inject.js"),
    });

    // The list of the bundled page's files and the lookup in it, which the shells of the platforms that embed the page import.
    _ = b.addModule("ziggy-ui-files", .{
        .root_source_file = b.path("src/lib/ui-files.zig"),
        .target = target,
        .optimize = optimize,
    });

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
    test_core_module.addAnonymousImport("ziggy-inject", .{
        .root_source_file = b.path("../bridge/inject/ziggy-inject.js"),
    });
    test_module.addImport(module_name, test_core_module);
    const unit_test = b.addTest(.{ .root_module = test_module });
    // The NDK has no libc.a for the sysroot's API level directory Zig looks in, only libc.so, so a test program for Android is
    // linked dynamically. Zig's build failed with "failed to parse archive: FileNotFound" on libc.a, libm.a and libdl.a.
    if (target.result.abi.isAndroid()) {
        unit_test.linkage = .dynamic;
    }
    // Installs the unit test program without running it, under zig-out/test-bin, for a target that cannot run it here: the
    // Android and iOS test scripts build it for their target and run it on the emulator or simulator.
    const test_binary_step = b.step("test-binary", "Build the unit test program and install it without running it");
    test_binary_step.dependOn(&b.addInstallArtifact(unit_test, .{
        .dest_dir = .{
            .override = .{
                .custom = "test-bin",
            },
        },
    }).step);
    const run_test = b.addRunArtifact(unit_test);
    run_test.setCwd(b.path("."));
    test_step.dependOn(&run_test.step);
}
//
// For a shell package's build.zig to offer its apps: makes the module that holds the app's built page, a list of every file under the page's
// directory (a path relative to the app's build.zig), each embedded with @embedFile. Pass the module to the app's shell
// code and give the list to AppConfig.ui_files. The directory is read every time the build runs, so whatever the page build
// produced is what gets embedded, with no list of files to keep up to date. A changed file rebuilds the executable. Fails
// the build when the directory is missing or has no index.html, which means the page was not built first.
//
pub fn embedPage(b: *std.Build, shell_module: *std.Build.Module, shell_import_name: []const u8, page_directory: []const u8) !*std.Build.Module {
    const io = b.graph.io;
    var directory = b.build_root.handle.openDir(io, page_directory, .{ .iterate = true }) catch |err| {
        std.debug.print("The built page is not in {s} ({s}). Build the page first.\n", .{ page_directory, @errorName(err) });
        return error.PageNotBuilt;
    };
    defer directory.close(io);

    var source: std.ArrayList(u8) = .empty;
    try source.appendSlice(b.allocator, b.fmt("const shell = @import(\"{s}\");\n\npub const files = [_]shell.UiFile{{\n", .{shell_import_name}));
    var embedded_names: std.ArrayList([]const u8) = .empty;
    var embedded_paths: std.ArrayList([]const u8) = .empty;
    var has_index = false;
    var walker = try directory.walk(b.allocator);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) {
            continue;
        }
        const path = b.dupe(entry.path);
        std.mem.replaceScalar(u8, path, '\\', '/');
        const import_name = b.fmt("ui-file-{d}", .{embedded_names.items.len});
        try embedded_names.append(b.allocator, import_name);
        try embedded_paths.append(b.allocator, b.fmt("{s}/{s}", .{ page_directory, path }));
        try source.appendSlice(b.allocator, b.fmt("    .{{ .path = \"{s}\", .content = @embedFile(\"{s}\") }},\n", .{ path, import_name }));
        if (std.mem.eql(u8, path, "index.html")) {
            has_index = true;
        }
    }
    if (!has_index) {
        std.debug.print("The built page in {s} has no index.html. Build the page first.\n", .{page_directory});
        return error.PageNotBuilt;
    }
    try source.appendSlice(b.allocator, "};\n");

    const generated = b.addWriteFiles();
    const module = b.createModule(.{
        .root_source_file = generated.add("ui-files.zig", source.items),
    });
    module.addImport(shell_import_name, shell_module);
    for (embedded_names.items, embedded_paths.items) |import_name, file_path| {
        module.addAnonymousImport(import_name, .{
            .root_source_file = b.path(file_path),
        });
    }
    return module;
}
