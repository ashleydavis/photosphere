const std = @import("std");

//
// The name of the module exposed by this package.
//
const module_name = "node-utils-zig";

//
// Names of the packages this package depends on.
//
const dependency_names = [_][]const u8{"utils-zig"};

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

        // os.homedir falls back to the passwd entry (getpwuid) when HOME is unset or empty.
        .link_libc = true,
    });
    for (dependency_names) |dependency_name| {
        const dependency = b.dependency(dependency_name, .{ .target = target, .optimize = optimize });
        module.addImport(dependency_name, dependency.module(dependency_name));
    }

    // The directory to write a kcov line-coverage report of the unit tests to (see docs/zig-test-coverage.md).
    // The tests are then compiled with the LLVM backend, whose debug info kcov reads, and run under kcov.
    const coverage_option = b.option([]const u8, "coverage", "Write a kcov line-coverage report of the unit tests to this directory");
    const coverage_dir: ?[]const u8 = if (coverage_option) |directory| b.pathFromRoot(directory) else null;

    // The process the termination tests send signals to; its path is handed to the tests as an option.
    const termination_child_module = b.createModule(.{
        .root_source_file = b.path("src/test/fixtures/termination-child.zig"),
        .target = target,
        .optimize = optimize,
    });
    termination_child_module.addImport(module_name, module);
    for (dependency_names) |dependency_name| {
        const dependency = b.dependency(dependency_name, .{ .target = target, .optimize = optimize });
        termination_child_module.addImport(dependency_name, dependency.module(dependency_name));
    }
    const termination_child = b.addExecutable(.{
        .name = "termination-child",
        .root_module = termination_child_module,
        .use_llvm = if (coverage_dir != null) true else null,
    });
    const test_options = b.addOptions();
    // For a coverage report the tests start a wrapper that runs the child under kcov, so the lines the child runs
    // (the signal handlers above all) are counted too.
    test_options.addOptionPath("termination_child_path", if (coverage_dir) |directory| coverageWrapper(b, termination_child, directory, target).getEmittedBin() else termination_child.getEmittedBin());

    const test_file = b.option([]const []const u8, "test-file", "Only run the tests of this file (e.g. path.test.zig); pass it more than once for several files");
    const test_step = b.step("test", "Run unit tests");
    // Every test file but termination.test.zig is compiled into one test program, whose root imports each of them.
    // Compiled one program per file, each linked the package and everything it depends on again, which was most of
    // the time the unit tests took (past the CI timeout on Windows). The src directory is copied next to the
    // generated root so that the imports and embedded files of the tests resolve as they do in src/test.
    const test_files = b.addWriteFiles();
    _ = test_files.addCopyDirectory(b.path("src"), "src", .{});
    var test_root_source: std.ArrayList(u8) = .empty;
    var termination_test_run: ?*std.Build.Step.Run = null;
    try test_root_source.appendSlice(b.allocator, "test {\n");
    var test_dir = try b.build_root.handle.openDir(b.graph.io, "src/test", .{ .iterate = true });
    defer test_dir.close(b.graph.io);
    var walker = try test_dir.walk(b.allocator);
    defer walker.deinit();
    while (try walker.next(b.graph.io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.path, ".test.zig")) {
            continue;
        }
        if (test_file) |only_files| {
            var is_wanted = false;
            for (only_files) |only_file| {
                if (std.mem.eql(u8, entry.path, only_file)) {
                    is_wanted = true;
                }
            }
            if (!is_wanted) {
                continue;
            }
        }

        // The termination tests read no fixtures, and the termination child path in the test options is relative
        // to the working directory of the build runner (the top-level build root, which differs from this package
        // when the tests run from the CLI's test-all), so they are a program of their own that runs where the
        // build runner runs.
        if (std.mem.eql(u8, entry.path, "termination.test.zig")) {
            const termination_module = b.createModule(.{
                .root_source_file = b.path("src/test/termination.test.zig"),
                .target = target,
                .optimize = optimize,
            });
            addTestImports(b, termination_module, module, test_options, target, optimize);
            const termination_test = b.addTest(.{ .name = "termination-test", .root_module = termination_module, .use_llvm = if (coverage_dir != null) true else null });
            // (Not under kcov itself, even for a coverage report: kcov traces the children of what it runs, and a
            // traced child cannot run under a kcov of its own. The child is where termination.zig is counted.)
            const run_termination_test = b.addRunArtifact(termination_test);
            test_step.dependOn(&run_termination_test.step);
            termination_test_run = run_termination_test;
            continue;
        }
        try test_root_source.appendSlice(b.allocator, b.fmt("    _ = @import(\"{s}\");\n", .{entry.path}));
    }
    try test_root_source.appendSlice(b.allocator, "}\n");
    const test_module = b.createModule(.{
        .root_source_file = test_files.add("src/test/all-tests.zig", test_root_source.items),
        .target = target,
        .optimize = optimize,
    });
    addTestImports(b, test_module, module, test_options, target, optimize);
    const unit_test = b.addTest(.{ .root_module = test_module, .use_llvm = if (coverage_dir != null) true else null });
    const run_test = if (coverage_dir) |directory| addCoverageRun(b, unit_test, directory) else b.addRunArtifact(unit_test);
    run_test.setCwd(b.path("."));
    test_step.dependOn(&run_test.step);
    if (coverage_dir != null) {
        // The termination tests start the termination child under a kcov of its own, which writes to the coverage
        // directory the kcov of the unit tests is writing to. Run at the same time, the two ended the unit test
        // program with a segmentation fault in _dl_fini, so the termination tests wait for the unit tests.
        if (termination_test_run) |run_termination_test| {
            run_termination_test.step.dependOn(&run_test.step);
        }
    }
}

//
// Adds the imports every test program of the package needs: the package, the test options and the dependencies.
//
fn addTestImports(b: *std.Build, test_module: *std.Build.Module, module: *std.Build.Module, test_options: *std.Build.Step.Options, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) void {
    test_module.addImport(module_name, module);
    test_module.addOptions("test-options", test_options);
    for (dependency_names) |dependency_name| {
        const dependency = b.dependency(dependency_name, .{ .target = target, .optimize = optimize });
        test_module.addImport(dependency_name, dependency.module(dependency_name));
    }
}

//
// Runs the unit test program under kcov, which writes a line-coverage report of this package's own sources (not its
// tests or dependencies) to the directory.
//
fn addCoverageRun(b: *std.Build, unit_test: *std.Build.Step.Compile, coverage_dir: []const u8) *std.Build.Step.Run {
    const run = b.addSystemCommand(&.{
        "kcov",
        b.fmt("--include-path={s}", .{b.pathFromRoot("src")}),
        b.fmt("--exclude-path={s}", .{b.pathFromRoot("src/test")}),
        coverage_dir,
    });
    run.addArtifactArg(unit_test);
    return run;
}

//
// Builds a program that replaces itself with kcov running the program, for a test that starts the program as a child
// of its own (src/test/fixtures/coverage-wrapper.zig).
//
fn coverageWrapper(b: *std.Build, program: *std.Build.Step.Compile, coverage_dir: []const u8, target: std.Build.ResolvedTarget) *std.Build.Step.Compile {
    const options = b.addOptions();
    options.addOption([]const u8, "kcov_path", b.findProgram(&.{"kcov"}, &.{}) catch @panic("kcov is not installed"));
    options.addOption([]const u8, "include_path", b.fmt("--include-path={s}", .{b.pathFromRoot("src")}));
    options.addOption([]const u8, "exclude_path", b.fmt("--exclude-path={s}", .{b.pathFromRoot("src/test")}));
    options.addOption([]const u8, "coverage_dir", coverage_dir);
    options.addOptionPath("program_path", program.getEmittedBin());
    const wrapper_module = b.createModule(.{
        .root_source_file = b.path("src/test/fixtures/coverage-wrapper.zig"),
        .target = target,
        .optimize = .Debug,
    });
    wrapper_module.addOptions("coverage_options", options);
    return b.addExecutable(.{
        .name = b.fmt("{s}-under-kcov", .{program.name}),
        .root_module = wrapper_module,
    });
}
