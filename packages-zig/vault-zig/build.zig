const std = @import("std");

//
// The name of the module exposed by this package.
//
const module_name = "vault-zig";

//
// Names of the packages this package depends on.
//
const dependency_names = [_][]const u8{ "utils-zig", "node-utils-zig" };

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

    const test_step = b.step("test", "Run unit tests");
    // Every test file is compiled into one test program, whose root imports each of them. Compiled one program
    // per file, each linked the package and everything it depends on again, which was most of the time the unit
    // tests took (past the CI timeout on Windows). The src directory is copied next to the generated root so that
    // the imports and embedded files of the tests resolve as they do in src/test. A test file named
    // *.own-process.test.zig is compiled into a test program of its own instead, so that it starts from the state a
    // fresh process has (a tool check not yet made, for one).
    const test_files = b.addWriteFiles();
    _ = test_files.addCopyDirectory(b.path("src"), "src", .{});
    var test_root_source: std.ArrayList(u8) = .empty;
    try test_root_source.appendSlice(b.allocator, "test {\n");
    var own_process_test_paths: std.ArrayList([]const u8) = .empty;
    var test_dir = try b.build_root.handle.openDir(b.graph.io, "src/test", .{ .iterate = true });
    defer test_dir.close(b.graph.io);
    var walker = try test_dir.walk(b.allocator);
    defer walker.deinit();
    while (try walker.next(b.graph.io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.path, ".test.zig")) {
            continue;
        }
        if (std.mem.endsWith(u8, entry.path, ".own-process.test.zig")) {
            try own_process_test_paths.append(b.allocator, b.dupe(entry.path));
            continue;
        }
        try test_root_source.appendSlice(b.allocator, b.fmt("    _ = @import(\"{s}\");\n", .{entry.path}));
    }
    try test_root_source.appendSlice(b.allocator, "}\n");

    // The directory to write a kcov line-coverage report of the unit tests to (see docs/zig-test-coverage.md).
    // The tests are then compiled with the LLVM backend, whose debug info kcov reads, and run under kcov.
    const coverage_dir = b.option([]const u8, "coverage", "Write a kcov line-coverage report of the unit tests to this directory");
    const stand_ins = addStandIns(b, target, optimize);
    addTestRun(b, test_step, test_files.add("src/test/all-tests.zig", test_root_source.items), module, target, optimize, coverage_dir, stand_ins);
    for (own_process_test_paths.items) |test_path| {
        addTestRun(b, test_step, test_files.getDirectory().path(b, b.fmt("src/test/{s}", .{test_path})), module, target, optimize, coverage_dir, stand_ins);
    }
}

//
// The names the stand-in tool (src/test/stand-in/stand-in.zig) is installed under for the tests: the tools the Linux
// and Windows keychain vaults run, and a plain program for the tests of runCommand.
//
const stand_in_names = [_][]const u8{ "which", "secret-tool", "powershell", "photosphere-stand-in-output" };

//
// The stand-in tools the test programs run in place of the real ones: the directory they are installed to and the
// step that installs them.
//
const IStandIns = struct {
    // The directory the stand-ins are installed to, put first on the PATH of the test programs.
    directory: []const u8,

    // The step that builds and installs the stand-ins.
    install_step: *std.Build.Step,
};

//
// Builds the stand-in tool and installs a copy of it under each name in stand_in_names to a directory of the install
// prefix (installed, rather than left in the cache, because the PATH of a test program is set before anything is
// built). The directory, one for each target, holds nothing but the stand-ins of that target: a PATH search would
// also find copies built for another target (wine runs a Linux program it finds that way, with no handle to wait on).
//
fn addStandIns(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) IStandIns {
    const stand_in = b.addExecutable(.{
        .name = "vault-stand-in",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/test/stand-in/stand-in.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const install_step = b.step("install-vault-stand-ins", "Install the stand-in tools the vault tests run");
    const install_dir: std.Build.InstallDir = .{
        .custom = b.fmt("vault-test-stand-ins/{s}", .{target.result.zigTriple(b.allocator) catch @panic("OOM")}),
    };
    for (stand_in_names) |stand_in_name| {
        const file_name = b.fmt("{s}{s}", .{ stand_in_name, target.result.exeFileExt() });
        install_step.dependOn(&b.addInstallFileWithDir(stand_in.getEmittedBin(), install_dir, file_name).step);
    }
    return .{
        .directory = b.getInstallPath(install_dir, ""),
        .install_step = install_step,
    };
}

//
// Compiles the test program whose root is `root_source_file` and runs it (under kcov when a coverage directory is
// given) from the package directory, with the stand-in tools first on its PATH.
//
fn addTestRun(
    b: *std.Build,
    test_step: *std.Build.Step,
    root_source_file: std.Build.LazyPath,
    module: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    coverage_dir: ?[]const u8,
    stand_ins: IStandIns,
) void {
    const test_module = b.createModule(.{
        .root_source_file = root_source_file,
        .target = target,
        .optimize = optimize,
    });
    test_module.addImport(module_name, module);
    for (dependency_names) |dependency_name| {
        const dependency = b.dependency(dependency_name, .{
            .target = target,
            .optimize = optimize,
        });
        test_module.addImport(dependency_name, dependency.module(dependency_name));
    }
    const unit_test = b.addTest(.{
        .root_module = test_module,
        .use_llvm = if (coverage_dir != null) true else null,
    });
    const run_test = if (coverage_dir) |directory| addCoverageRun(b, unit_test, directory) else b.addRunArtifact(unit_test);
    run_test.setCwd(b.path("."));

    // Under wine a Windows program searches WINEPATH (before the PATH of the wine prefix) instead of PATH.
    const use_wine = b.enable_wine and b.graph.host.result.os.tag != .windows and target.result.os.tag == .windows;
    const path_variable = if (use_wine) "WINEPATH" else "PATH";
    const path_delimiter: u8 = if (use_wine or target.result.os.tag == .windows) ';' else ':';
    const environ_map = run_test.getEnvMap();
    const search_path = if (environ_map.get(path_variable)) |previous_path|
        b.fmt("{s}{c}{s}", .{ stand_ins.directory, path_delimiter, previous_path })
    else
        stand_ins.directory;
    run_test.setEnvironmentVariable(path_variable, search_path);
    run_test.step.dependOn(stand_ins.install_step);
    test_step.dependOn(&run_test.step);
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
