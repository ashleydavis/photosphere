const std = @import("std");
const aws_lc = @import("packages-zig/encryption-zig/aws/aws-lc.zig");
const aws_sdk = @import("packages-zig/storage-zig/aws/aws-sdk.zig");
const zlib_ng = @import("packages-zig/serialization-zig/zlib-ng/zlib-ng.zig");

//
// A Zig package in this directory: its module is the `src/index.zig` of the directory of the same name.
//
const IPackage = struct {
    // The name of the package, which is the name of its directory and of its module.
    name: []const u8,

    // The names of the packages whose modules this package's module imports. Each is listed before this package in
    // `packages`, so that its module exists by the time it is imported.
    dependencies: []const []const u8,

    // Whether the module links libc.
    link_libc: bool,
};

//
// Every Zig package in this directory, each after the packages it depends on.
//
const packages = [_]IPackage{
    .{ .name = "utils-zig", .dependencies = &.{}, .link_libc = false },
    .{ .name = "fuzzy-match-zig", .dependencies = &.{}, .link_libc = false },
    .{ .name = "lan-share-core-zig", .dependencies = &.{}, .link_libc = false },
    .{ .name = "node-utils-zig", .dependencies = &.{"utils-zig"}, .link_libc = true },
    .{ .name = "encryption-zig", .dependencies = &.{"utils-zig"}, .link_libc = false },
    .{ .name = "serialization-zig", .dependencies = &.{"utils-zig"}, .link_libc = false },
    .{ .name = "task-queue-zig", .dependencies = &.{ "utils-zig", "node-utils-zig" }, .link_libc = false },
    .{ .name = "tools-zig", .dependencies = &.{ "utils-zig", "node-utils-zig", "serialization-zig" }, .link_libc = false },
    .{ .name = "vault-zig", .dependencies = &.{ "utils-zig", "node-utils-zig" }, .link_libc = false },
    .{ .name = "storage-zig", .dependencies = &.{ "utils-zig", "node-utils-zig", "encryption-zig" }, .link_libc = false },
    .{ .name = "merkle-tree-zig", .dependencies = &.{ "utils-zig", "serialization-zig", "storage-zig" }, .link_libc = false },
    .{ .name = "bdb-zig", .dependencies = &.{ "utils-zig", "serialization-zig", "storage-zig", "merkle-tree-zig" }, .link_libc = false },
    .{ .name = "lan-share-network-zig", .dependencies = &.{ "utils-zig", "node-utils-zig", "encryption-zig" }, .link_libc = true },
    .{ .name = "api-zig", .dependencies = &.{ "utils-zig", "storage-zig", "serialization-zig", "task-queue-zig", "vault-zig", "lan-share-core-zig", "node-utils-zig", "encryption-zig", "bdb-zig" }, .link_libc = false },
    .{ .name = "node-api-zig", .dependencies = &.{ "utils-zig", "node-utils-zig", "encryption-zig", "serialization-zig", "storage-zig", "merkle-tree-zig", "bdb-zig", "api-zig", "task-queue-zig", "vault-zig", "tools-zig" }, .link_libc = false },
    .{ .name = "photosphere-core", .dependencies = &.{ "utils-zig", "node-utils-zig", "tools-zig", "encryption-zig", "storage-zig", "vault-zig", "task-queue-zig", "serialization-zig", "merkle-tree-zig", "bdb-zig", "api-zig", "node-api-zig" }, .link_libc = true },
};

//
// The libcrypto headers encryption-zig's node-crypto.zig uses, translated to Zig as the "openssl" module of that package.
//
const encryption_openssl_header =
    \\#include <openssl/bio.h>
    \\#include <openssl/bn.h>
    \\#include <openssl/cipher.h>
    \\#include <openssl/err.h>
    \\#include <openssl/evp.h>
    \\#include <openssl/mem.h>
    \\#include <openssl/pem.h>
    \\#include <openssl/rand.h>
    \\#include <openssl/rsa.h>
    \\#include <openssl/x509.h>
    \\
;

//
// The libssl and libcrypto headers lan-share-network-zig's HTTPS server and client use, translated to Zig as the "openssl"
// module of that package.
//
const lan_share_openssl_header =
    \\#include <openssl/bio.h>
    \\#include <openssl/err.h>
    \\#include <openssl/evp.h>
    \\#include <openssl/pem.h>
    \\#include <openssl/ssl.h>
    \\#include <openssl/x509.h>
    \\
;

//
// The names the stand-in tool (vault-zig/src/test/stand-in/stand-in.zig) is installed under for the tests: the tools the Linux
// and Windows keychain vaults run, and a plain program for the tests of runCommand.
//
const stand_in_names = [_][]const u8{ "which", "secret-tool", "powershell", "photosphere-stand-in-output" };

//
// The stand-in tools the test programs run in place of the real ones: the directory they are installed to and the step that
// installs them.
//
const IStandIns = struct {
    // The directory the stand-ins are installed to, put first on the PATH of the test programs.
    directory: []const u8,

    // The step that builds and installs the stand-ins.
    install_step: *std.Build.Step,
};

//
// Builds every Zig package here and registers `test`, which runs the unit tests of all of them in one test program. Every
// package's test files are compiled into that one program, so the packages' dependencies are built and linked once. The
// tests that need a process of their own (they start from a fresh process, or run a child) are separate programs, run by the
// same step.
//
// The tests read their fixtures with paths relative to this directory, which the test programs run in.
//
pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    // ReleaseSafe by default: the tests keep the safety checks, and the work of the database and storage tests is several times
    // slower in Debug.
    const optimize = b.option(std.builtin.OptimizeMode, "optimize", "Prioritize performance, safety, or binary size (default: ReleaseSafe)") orelse .ReleaseSafe;

    const ziggy_core = try addZiggyCore(b, target, optimize, false);
    const modules = try addPackageModules(b, target, optimize, ziggy_core.module);

    const test_step = b.step("test", "Run every Zig test: the unit tests of the packages and the tests of the CLI");
    const test_packages_step = internalStep(b, "unit tests of the packages");
    const test_cli_step = internalStep(b, "tests of the CLI");
    test_step.dependOn(test_packages_step);
    test_step.dependOn(test_cli_step);
    const stand_ins = addStandIns(b, target, optimize);
    try addUnitTests(b, test_packages_step, modules, target, optimize, stand_ins);
    try addOwnProcessTests(b, test_packages_step, modules, target, optimize, stand_ins);
    try addStorageIntegrationTests(b, modules, target, optimize);
    try addCli(b, test_cli_step, modules, target, optimize);
    const test_ziggy_step = internalStep(b, "tests of Ziggy and of the Ziggy example");
    try addZiggy(b, test_ziggy_step, target, optimize);
    test_step.dependOn(test_ziggy_step);

    // Prints the time the build took after the tests: Zig's summary gives the time of each step and no total.
    const elapsed = b.allocator.create(ElapsedStep) catch @panic("out of memory");
    elapsed.* = .{
        .step = std.Build.Step.init(.{
            .id = .custom,
            .name = "print the total time",
            .owner = b,
            .makeFn = ElapsedStep.make,
        }),
        .started_ms = std.Io.Clock.real.now(b.graph.io).toMilliseconds(),
    };
    // Stands for the unit tests, so the total time step lists this one step under itself in Zig's summary instead of each of them.
    const tests_done = b.allocator.create(std.Build.Step) catch @panic("out of memory");
    tests_done.* = std.Build.Step.init(.{
        .id = .custom,
        .name = "unit tests",
        .owner = b,
    });
    for (test_step.dependencies.items) |dependency_step| {
        tests_done.dependOn(dependency_step);
    }
    elapsed.step.dependOn(tests_done);
    test_step.dependOn(&elapsed.step);
}

//
// Creates the module of every package, with the libraries the packages need, and returns them by name.
//
fn addPackageModules(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    ziggy_core: *std.Build.Module,
) !std.StringHashMap(*std.Build.Module) {
    var modules = std.StringHashMap(*std.Build.Module).init(b.allocator);
    var crypto: ?*std.Build.Step.Compile = null;
    var ssl: ?*std.Build.Step.Compile = null;

    for (packages) |package| {
        const module = b.addModule(package.name, .{
            .root_source_file = b.path(b.fmt("packages-zig/{s}/src/index.zig", .{package.name})),
            .target = target,
            .optimize = optimize,
            .link_libc = if (package.link_libc) true else null,
        });
        for (package.dependencies) |dependency_name| {
            module.addImport(dependency_name, modules.get(dependency_name).?);
        }
        try modules.put(package.name, module);

        if (std.mem.eql(u8, package.name, "encryption-zig")) {
            // aws-lc's libcrypto, whose functions node-crypto.zig calls and which the AWS SDK for C links as well, and libssl
            // over it for lan-share-network-zig.
            crypto = try aws_lc.build(b, target, b.dependency("aws-lc", .{}));
            module.linkLibrary(crypto.?);
            ssl = try aws_lc.buildSsl(b, target, b.dependency("aws-lc", .{}), crypto.?);
            module.addImport("openssl", translateHeader(b, target, crypto.?, encryption_openssl_header));
        }
        if (std.mem.eql(u8, package.name, "serialization-zig")) {
            // zlib-ng, which gzip compression and decompression bind to.
            try zlib_ng.addZlibNg(b, module, target);
        }
        if (std.mem.eql(u8, package.name, "storage-zig")) {
            // The AWS SDK for C, which the S3 client binds to, over the libcrypto that encryption-zig builds. False means a lazy
            // dependency is being fetched first.
            if (!try aws_sdk.addAwsSdk(b, module, target, crypto.?)) {
                return modules;
            }
        }
        if (std.mem.eql(u8, package.name, "lan-share-network-zig")) {
            module.linkLibrary(ssl.?);
            if (target.result.os.tag == .windows) {
                module.linkSystemLibrary("ws2_32", .{});
            }
            module.addImport("openssl", translateHeader(b, target, crypto.?, lan_share_openssl_header));
        }
        if (std.mem.eql(u8, package.name, "photosphere-core")) {
            module.addImport("ziggy-core", ziggy_core);
        }
    }
    return modules;
}

//
// Translates C headers that include libcrypto's to a Zig module. Translated without optimization: in the optimized modes the
// MinGW headers define fortified inline wrappers of memset and friends, which translate-c turns into Zig that does not
// compile. The declarations are the same.
//
fn translateHeader(b: *std.Build, target: std.Build.ResolvedTarget, crypto: *std.Build.Step.Compile, header: []const u8) *std.Build.Module {
    const translate_c = b.addTranslateC(.{
        .root_source_file = b.addWriteFiles().add("openssl.h", header),
        .target = target,
        .optimize = .Debug,
    });
    translate_c.addIncludePath(crypto.getEmittedIncludeTree());
    return translate_c.createModule();
}

//
// Compiles the test files of every package into one test program and runs it from the packages-zig directory with the vault stand-ins
// first on its PATH.
//
fn addUnitTests(
    b: *std.Build,
    test_step: *std.Build.Step,
    modules: std.StringHashMap(*std.Build.Module),
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    stand_ins: IStandIns,
) !void {
    // The src directory of each package is copied next to the generated root, under the package's name, so that the imports and
    // embedded files of its tests resolve as they do in src/test.
    const test_files = b.addWriteFiles();
    const only_file = b.option([]const u8, "test-file", "Only run the tests of this file (for example bdb-zig/merkle-tree.test.zig)");
    var test_root_source: std.ArrayList(u8) = .empty;
    try test_root_source.appendSlice(b.allocator, "test {\n");
    for (packages) |package| {
        _ = test_files.addCopyDirectory(b.path(b.fmt("packages-zig/{s}/src", .{package.name})), b.fmt("{s}/src", .{package.name}), .{});
        var test_dir = try b.build_root.handle.openDir(b.graph.io, b.fmt("packages-zig/{s}/src/test", .{package.name}), .{ .iterate = true });
        defer test_dir.close(b.graph.io);
        var walker = try test_dir.walk(b.allocator);
        defer walker.deinit();
        while (try walker.next(b.graph.io)) |entry| {
            if (entry.kind != .file or !std.mem.endsWith(u8, entry.path, ".test.zig")) {
                continue;
            }
            if (isOwnProcessTest(package.name, entry.path)) {
                continue;
            }
            if (only_file) |only| {
                if (!std.mem.eql(u8, only, b.fmt("{s}/{s}", .{ package.name, entry.path }))) {
                    continue;
                }
            }
            try test_root_source.appendSlice(b.allocator, b.fmt("    _ = @import(\"{s}/src/test/{s}\");\n", .{ package.name, entry.path }));
        }
    }
    try test_root_source.appendSlice(b.allocator, "}\n");

    const test_module = b.createModule(.{
        .root_source_file = test_files.add("all-tests.zig", test_root_source.items),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    var module_iterator = modules.iterator();
    while (module_iterator.next()) |entry| {
        // The tests of photosphere-core import its files by path, and run it with the test hooks of Ziggy's core compiled in.
        if (std.mem.eql(u8, entry.key_ptr.*, "photosphere-core")) {
            continue;
        }
        test_module.addImport(entry.key_ptr.*, entry.value_ptr.*);
    }
    // The modules the tests of encryption-zig and storage-zig import that are not packages: the C headers each of them translates.
    const encryption = modules.get("encryption-zig").?;
    test_module.addImport("openssl", encryption.import_table.get("openssl").?);
    const storage = modules.get("storage-zig").?;
    test_module.addImport(aws_sdk.aws_c_module_name, storage.import_table.get(aws_sdk.aws_c_module_name).?);
    const test_ziggy_core = try addZiggyCore(b, target, optimize, true);
    test_module.addImport("ziggy-core", test_ziggy_core.module);

    // The directory to write a kcov line-coverage report of the unit tests to (see docs/zig-test-coverage.md). The tests are then
    // compiled with the LLVM backend, whose debug info kcov reads, and run under kcov.
    const coverage_dir = b.option([]const u8, "coverage", "Write a kcov line-coverage report of the unit tests of the packages to this directory");
    const unit_test = b.addTest(.{
        .name = "unit-tests",
        .root_module = test_module,
        .use_llvm = if (coverage_dir != null) true else null,
    });
    const run_test = if (coverage_dir) |directory| try addCoverageRun(b, unit_test, directory) else b.addRunArtifact(unit_test);
    run_test.setCwd(b.path("packages-zig"));
    addStandInsToPath(b, run_test, target, stand_ins);
    test_step.dependOn(&run_test.step);
}

//
// Whether a test file needs a process of its own: the termination tests send signals to a child they start, and the tests of the
// keychain vaults must start from the state of a fresh process (a tool check not yet made, for one).
//
fn isOwnProcessTest(package_name: []const u8, path: []const u8) bool {
    if (std.mem.eql(u8, package_name, "node-utils-zig") and std.mem.eql(u8, path, "termination.test.zig")) {
        return true;
    }
    return std.mem.endsWith(u8, path, ".own-process.test.zig");
}

//
// Adds the tests that are a program of their own: the termination tests of node-utils-zig, the program of utils-zig that writes
// to the real stdout (the build checks what it printed) and the own-process tests of vault-zig.
//
fn addOwnProcessTests(
    b: *std.Build,
    test_step: *std.Build.Step,
    modules: std.StringHashMap(*std.Build.Module),
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    stand_ins: IStandIns,
) !void {
    // The termination tests: they start a child process, whose path is handed to them as an option, and send it signals.
    const termination_child_module = b.createModule(.{
        .root_source_file = b.path("packages-zig/node-utils-zig/src/test/fixtures/termination-child.zig"),
        .target = target,
        .optimize = optimize,
    });
    termination_child_module.addImport("node-utils-zig", modules.get("node-utils-zig").?);
    termination_child_module.addImport("utils-zig", modules.get("utils-zig").?);
    const termination_child = b.addExecutable(.{
        .name = "termination-child",
        .root_module = termination_child_module,
    });
    const termination_options = b.addOptions();
    termination_options.addOptionPath("termination_child_path", termination_child.getEmittedBin());
    const termination_module = b.createModule(.{
        .root_source_file = b.path("packages-zig/node-utils-zig/src/test/termination.test.zig"),
        .target = target,
        .optimize = optimize,
    });
    termination_module.addImport("node-utils-zig", modules.get("node-utils-zig").?);
    termination_module.addImport("utils-zig", modules.get("utils-zig").?);
    termination_module.addOptions("test-options", termination_options);
    const termination_test = b.addTest(.{
        .name = "termination-test",
        .root_module = termination_module,
    });
    test_step.dependOn(&b.addRunArtifact(termination_test).step);

    // The console writing to the real stdout, which a unit test cannot see: a program writes through it and the build checks what it
    // printed.
    const console_stdout_module = b.createModule(.{
        .root_source_file = b.path("packages-zig/utils-zig/src/test/fixtures/console-stdout.zig"),
        .target = target,
        .optimize = optimize,
    });
    console_stdout_module.addImport("utils-zig", modules.get("utils-zig").?);
    const console_stdout = b.addExecutable(.{
        .name = "console-stdout",
        .root_module = console_stdout_module,
    });
    const run_console_stdout = b.addRunArtifact(console_stdout);
    run_console_stdout.expectStdOutEqual("logged to stdout\ndebugged to stdout\n");
    test_step.dependOn(&run_console_stdout.step);

    // The tests of the keychain vaults, each a program of its own.
    var vault_test_dir = try b.build_root.handle.openDir(b.graph.io, "packages-zig/vault-zig/src/test", .{ .iterate = true });
    defer vault_test_dir.close(b.graph.io);
    var walker = try vault_test_dir.walk(b.allocator);
    defer walker.deinit();
    while (try walker.next(b.graph.io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.path, ".own-process.test.zig")) {
            continue;
        }
        const own_process_module = b.createModule(.{
            .root_source_file = b.path(b.fmt("packages-zig/vault-zig/src/test/{s}", .{entry.path})),
            .target = target,
            .optimize = optimize,
        });
        own_process_module.addImport("vault-zig", modules.get("vault-zig").?);
        own_process_module.addImport("utils-zig", modules.get("utils-zig").?);
        own_process_module.addImport("node-utils-zig", modules.get("node-utils-zig").?);
        const own_process_test = b.addTest(.{
            .root_module = own_process_module,
        });
        const run_own_process_test = b.addRunArtifact(own_process_test);
        run_own_process_test.setCwd(b.path("packages-zig"));
        addStandInsToPath(b, run_own_process_test, target, stand_ins);
        test_step.dependOn(&run_own_process_test.step);
    }
}

//
// Adds the storage package's integration tests, which run against the real S3 server the environment names. They are not part of
// the unit tests: they always run when asked for, because what they test is the server, which the build cannot see change.
//
fn addStorageIntegrationTests(
    b: *std.Build,
    modules: std.StringHashMap(*std.Build.Module),
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) !void {
    const integration_test_step = b.step("test-integration", "Run the storage integration tests against the S3 server the environment names");
    const integration_test_module = b.createModule(.{
        .root_source_file = b.path("packages-zig/storage-zig/integration-tests/cloud-storage.test.zig"),
        .target = target,
        .optimize = optimize,
    });
    for ([_][]const u8{ "storage-zig", "utils-zig", "node-utils-zig", "encryption-zig" }) |module_name| {
        integration_test_module.addImport(module_name, modules.get(module_name).?);
    }
    const integration_test = b.addTest(.{
        .name = "integration-test",
        .root_module = integration_test_module,
    });
    const run_integration_test = b.addRunArtifact(integration_test);
    run_integration_test.has_side_effects = true;
    integration_test_step.dependOn(&run_integration_test.step);
}

//
// Builds the stand-in tool and installs a copy of it under each name in stand_in_names to a directory of the install prefix
// (installed, rather than left in the cache, because the PATH of a test program is set before anything is built). The
// directory, one for each target, holds nothing but the stand-ins of that target: a PATH search would also find copies built for
// another target (wine runs a Linux program it finds that way, with no handle to wait on).
//
fn addStandIns(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) IStandIns {
    const stand_in = b.addExecutable(.{
        .name = "vault-stand-in",
        .root_module = b.createModule(.{
            .root_source_file = b.path("packages-zig/vault-zig/src/test/stand-in/stand-in.zig"),
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
        .directory = b.pathResolve(&.{ b.graph.cache.cwd, b.getInstallPath(install_dir, "") }),
        .install_step = install_step,
    };
}

//
// Puts the stand-in tools first on the PATH of a test program, and makes it wait for them to be installed. Under wine a Windows
// program searches WINEPATH (before the PATH of the wine prefix) instead of PATH.
//
fn addStandInsToPath(b: *std.Build, run: *std.Build.Step.Run, target: std.Build.ResolvedTarget, stand_ins: IStandIns) void {
    const use_wine = b.enable_wine and b.graph.host.result.os.tag != .windows and target.result.os.tag == .windows;
    const path_variable = if (use_wine) "WINEPATH" else "PATH";
    const path_delimiter: u8 = if (use_wine or target.result.os.tag == .windows) ';' else ':';
    const environ_map = run.getEnvMap();
    const search_path = if (environ_map.get(path_variable)) |previous_path|
        b.fmt("{s}{c}{s}", .{ stand_ins.directory, path_delimiter, previous_path })
    else
        stand_ins.directory;
    run.setEnvironmentVariable(path_variable, search_path);
    run.step.dependOn(stand_ins.install_step);
}

//
// A step that prints how long the build has been running. Zig's own summary gives the time of each step and no total, so this is the
// last step of `test`: it depends on the unit tests and runs after them.
//
const ElapsedStep = struct {
    // The step Zig runs.
    step: std.Build.Step,
    // When the build started, in milliseconds since the Unix epoch.
    started_ms: i64,

    //
    // Prints the time since the build started.
    //
    fn make(step: *std.Build.Step, options: std.Build.Step.MakeOptions) anyerror!void {
        _ = options;
        const self: *ElapsedStep = @fieldParentPtr("step", step);
        const now_ms = std.Io.Clock.real.now(step.owner.graph.io).toMilliseconds();
        const elapsed_seconds = @as(f64, @floatFromInt(now_ms - self.started_ms)) / 1000.0;
        std.debug.print("Total time: {d:.1}s\n", .{elapsed_seconds});

        // Zig's `--summary all` tree shows a duration beside a step that has one, and prints this step last, so this puts the total at
        // the bottom of the summary instead of far above it.
        step.result_duration_ns = @intCast((now_ms - self.started_ms) * std.time.ns_per_ms);
    }
};

//
// The names of the packages the CLI imports.
//
const cli_dependency_names = [_][]const u8{
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
// Builds the CLI (`psi`, installed to zig-out/bin) and registers its tests. The tests run psi and a test driver (a program
// that runs CLI functions against the real process streams, installed to zig-out/test-bin, which is not shipped) from
// apps/cli-zig, and need both installed first.
//
fn addCli(
    b: *std.Build,
    test_step: *std.Build.Step,
    modules: std.StringHashMap(*std.Build.Module),
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) !void {
    const cli_module = b.addModule("cli-zig", .{
        .root_source_file = b.path("apps/cli-zig/index.zig"),
        .target = target,
        .optimize = optimize,
    });
    for (cli_dependency_names) |dependency_name| {
        cli_module.addImport(dependency_name, modules.get(dependency_name).?);
    }
    const psi = b.addExecutable(.{
        .name = "psi",
        .root_module = cli_module,
    });
    b.installArtifact(psi);

    // Every test file is compiled into one test program, whose root imports each of them. The test files, with test-helpers.zig
    // beside them, are copied next to the generated root so that its imports and theirs resolve as they do in src/test.
    const only_file = b.option([]const u8, "cli-test-file", "Only run the tests of this file of the CLI (for example prompts.test.zig)");
    const test_files = b.addWriteFiles();
    var test_root_source: std.ArrayList(u8) = .empty;
    try test_root_source.appendSlice(b.allocator, "test {\n");
    var test_dir = try b.build_root.handle.openDir(b.graph.io, "apps/cli-zig/src/test", .{ .iterate = true });
    defer test_dir.close(b.graph.io);
    var walker = try test_dir.walk(b.allocator);
    defer walker.deinit();
    while (try walker.next(b.graph.io)) |entry| {
        if (entry.kind != .file or entry.depth() != 1 or !std.mem.endsWith(u8, entry.path, ".zig")) {
            continue;
        }
        _ = test_files.addCopyFile(b.path(b.fmt("apps/cli-zig/src/test/{s}", .{entry.path})), entry.path);
        if (!std.mem.endsWith(u8, entry.path, ".test.zig")) {
            continue;
        }
        if (only_file) |only| {
            if (!std.mem.eql(u8, only, entry.path)) {
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
    test_module.addImport("cli-zig", cli_module);
    for (cli_dependency_names) |dependency_name| {
        test_module.addImport(dependency_name, modules.get(dependency_name).?);
    }
    const unit_test = b.addTest(.{
        .name = "cli-tests",
        .root_module = test_module,
    });
    const run_test = b.addRunArtifact(unit_test);
    run_test.setCwd(b.path("apps/cli-zig"));
    run_test.step.dependOn(b.getInstallStep());

    // The program the tests run CLI functions in, against the real process streams (installed to zig-out/test-bin, not zig-out/bin:
    // it is not shipped).
    const test_driver_module = b.createModule(.{
        .root_source_file = b.path("apps/cli-zig/src/test/drivers/test-driver.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_driver_module.addImport("cli-zig", cli_module);
    for (cli_dependency_names) |dependency_name| {
        test_driver_module.addImport(dependency_name, modules.get(dependency_name).?);
    }
    const test_driver = b.addExecutable(.{
        .name = "test-driver",
        .root_module = test_driver_module,
    });
    const install_test_driver = b.addInstallArtifact(test_driver, .{
        .dest_dir = .{
            .override = .{
                .custom = "test-bin",
            },
        },
    });
    run_test.step.dependOn(&install_test_driver.step);
    test_step.dependOn(&run_test.step);
}

//
// The modules of a build of Ziggy's core: the core itself and the list of the bundled page's files.
//
const IZiggyCore = struct {
    // The core, imported as "ziggy-core".
    module: *std.Build.Module,

    // The list of the bundled page's files and the lookup in it, which the shells of the platforms that embed the page import.
    ui_files_module: *std.Build.Module,
};

//
// Makes the modules of Ziggy's core. The test hooks compile in the test control connection: they are off for a release and on for
// the tests and for the builds the smoke tests drive.
//
fn addZiggyCore(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    test_hooks: bool,
) !IZiggyCore {
    const options = b.addOptions();
    options.addOption(bool, "test_hooks", test_hooks);

    const module = b.createModule(.{
        .root_source_file = b.path("packages/ziggy/core/src/index.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    module.addOptions("build_options", options);
    module.addAnonymousImport("ziggy-inject", .{
        .root_source_file = b.path("packages/ziggy/bridge/inject/ziggy-inject.js"),
    });

    const ui_files_module = b.createModule(.{
        .root_source_file = b.path("packages/ziggy/core/src/lib/ui-files.zig"),
        .target = target,
        .optimize = optimize,
    });

    // The Android shell reaches the core through JNI, written in Zig against the NDK's own jni.h. Only an Android target has that
    // header, so the import exists only for one.
    if (target.result.abi.isAndroid()) {
        const jni_translate_c = b.addTranslateC(.{
            .root_source_file = b.path("packages/ziggy/core/src/lib/jni-c.h"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        // Zig has no C library headers for Android. They come from the NDK, through the libc file the build is given with --libc,
        // and the translation step is not given that file, so its include directories are read out of it here.
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
    return .{
        .module = module,
        .ui_files_module = ui_files_module,
    };
}

//
// Makes the module that holds an app's built page, a list of every file under the page's directory (a path relative to the root of
// the repository), each embedded with @embedFile. Pass the module to the app's shell code and give the list to AppConfig.ui_files.
// The directory is read every time the build runs, so whatever the page build produced is what gets embedded, with no list of files
// to keep up to date. A changed file rebuilds the executable. When the directory is missing or has no index.html, which means the
// page was not built first, the module does not compile and says so: the build of anything that does not use the page is not
// affected.
//
fn embedPage(b: *std.Build, shell_module: *std.Build.Module, shell_import_name: []const u8, page_directory: []const u8) !*std.Build.Module {
    const io = b.graph.io;
    var source: std.ArrayList(u8) = .empty;
    var embedded_names: std.ArrayList([]const u8) = .empty;
    var embedded_paths: std.ArrayList([]const u8) = .empty;
    var has_index = false;
    if (b.build_root.handle.openDir(io, page_directory, .{ .iterate = true })) |opened| {
        var directory = opened;
        defer directory.close(io);
        try source.appendSlice(b.allocator, b.fmt("const shell = @import(\"{s}\");\n\npub const files = [_]shell.UiFile{{\n", .{shell_import_name}));
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
        try source.appendSlice(b.allocator, "};\n");
    } else |_| {}
    if (!has_index) {
        source.clearRetainingCapacity();
        embedded_names.clearRetainingCapacity();
        embedded_paths.clearRetainingCapacity();
        try source.appendSlice(b.allocator, b.fmt("comptime {{\n    @compileError(\"The built page is not in {s}, or has no index.html. Build the page first.\");\n}}\n", .{page_directory}));
    }

    const generated = b.addWriteFiles();
    const module = b.createModule(.{
        .root_source_file = generated.add("ui-files.zig", source.items),
    });
    if (has_index) {
        module.addImport(shell_import_name, shell_module);
    }
    for (embedded_names.items, embedded_paths.items) |import_name, file_path| {
        module.addAnonymousImport(import_name, .{
            .root_source_file = b.path(file_path),
        });
    }
    return module;
}

//
// The directories a Linux system keeps its shared libraries in, checked in this order.
//
const library_directories = [_][]const u8{
    "/usr/lib/x86_64-linux-gnu",
    "/usr/lib/aarch64-linux-gnu",
    "/lib/x86_64-linux-gnu",
    "/lib/aarch64-linux-gnu",
    "/usr/lib64",
    "/usr/lib",
    "/lib64",
    "/lib",
};

//
// Finds an installed runtime library by its file name and returns its full path. Fails the build, saying which library is missing and
// where it looked, when it is in none of the usual directories.
//
fn findRuntimeLibrary(b: *std.Build, file_name: []const u8) ![]const u8 {
    for (library_directories) |directory| {
        const path = b.fmt("{s}/{s}", .{ directory, file_name });
        std.Io.Dir.cwd().access(b.graph.io, path, .{}) catch {
            continue;
        };
        return path;
    }
    std.debug.print("The runtime library {s} is not installed. Looked in:\n", .{file_name});
    for (library_directories) |directory| {
        std.debug.print("  {s}\n", .{directory});
    }
    return error.RuntimeLibraryMissing;
}

//
// Compiles the test files under `<directory>/src/test` into one test program whose modules are given, and returns the run step. The
// src directory is copied next to the generated root so that the imports of the tests resolve as they do in src/test. The program runs
// from `directory`.
//
fn addDirectoryTests(
    b: *std.Build,
    test_step: *std.Build.Step,
    directory: []const u8,
    imports: []const IImport,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    test_binary_step: ?*std.Build.Step,
) !void {
    const test_files = b.addWriteFiles();
    _ = test_files.addCopyDirectory(b.path(b.fmt("{s}/src", .{directory})), "src", .{});
    var test_root_source: std.ArrayList(u8) = .empty;
    try test_root_source.appendSlice(b.allocator, "test {\n");
    var test_dir = try b.build_root.handle.openDir(b.graph.io, b.fmt("{s}/src/test", .{directory}), .{ .iterate = true });
    defer test_dir.close(b.graph.io);
    var walker = try test_dir.walk(b.allocator);
    defer walker.deinit();
    while (try walker.next(b.graph.io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.path, ".test.zig")) {
            continue;
        }
        try test_root_source.appendSlice(b.allocator, b.fmt("    _ = @import(\"src/test/{s}\");\n", .{entry.path}));
    }
    try test_root_source.appendSlice(b.allocator, "}\n");
    const test_module = b.createModule(.{
        .root_source_file = test_files.add("all-tests.zig", test_root_source.items),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    for (imports) |import| {
        test_module.addImport(import.name, import.module);
    }
    // Zig does not look in the iOS SDK for libSystem unless it is given the library directory, which --sysroot then makes the SDK's.
    // A test program for the iOS simulator failed to link with "unable to find libSystem system library" with only the sysroot given,
    // and linked past that once /usr/lib was added as a library path.
    if (target.result.os.tag == .ios) {
        test_module.addLibraryPath(.{ .cwd_relative = "/usr/lib" });
    }
    const unit_test = b.addTest(.{
        .name = std.fs.path.basename(directory),
        .root_module = test_module,
    });
    // The NDK has no libc.a for the sysroot's API level directory Zig looks in, only libc.so, so a test program for Android is linked
    // dynamically. Zig's build failed with "failed to parse archive: FileNotFound" on libc.a, libm.a and libdl.a.
    if (target.result.abi.isAndroid()) {
        unit_test.linkage = .dynamic;
    }
    // Installs the unit test program without running it, under test-bin, for a target that cannot run it here: the Android and iOS test
    // scripts build it for their target and run it on the emulator or simulator.
    if (test_binary_step) |step| {
        step.dependOn(&b.addInstallArtifact(unit_test, .{
            .dest_dir = .{
                .override = .{
                    .custom = "test-bin",
                },
            },
        }).step);
    }
    const run_test = b.addRunArtifact(unit_test);
    run_test.setCwd(b.path(directory));
    test_step.dependOn(&run_test.step);
}

//
// A module a test program imports, and the name it imports it under.
//
const IImport = struct {
    // The name the tests import the module under.
    name: []const u8,

    // The module.
    module: *std.Build.Module,
};

//
// Builds Ziggy, the shell its apps stand on, and the Ziggy example app, and registers their tests. The platform shells that are not Zig
// (the Xcode projects and the Android project) are built by the scripts of the app, which ask this build for the core's libraries.
//
fn addZiggy(
    b: *std.Build,
    test_step: *std.Build.Step,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) !void {
    const test_hooks = b.option(bool, "test-hooks", "Build the test hooks (the test control connection) into the app (never for a release)") orelse false;
    const core = try addZiggyCore(b, target, optimize, test_hooks);
    const test_core = try addZiggyCore(b, target, optimize, true);

    // The unit tests of Ziggy's core, which run the core with the test hooks compiled in.
    const core_test_binary_step = b.step("test-binary-ziggy-core", "Build the unit test program of Ziggy's core and install it to test-bin without running it");
    try addDirectoryTests(b, test_step, "packages/ziggy/core", &.{.{ .name = "ziggy-core", .module = test_core.module }}, target, optimize, core_test_binary_step);

    // The unit tests of the parts of the shells that do not need the platform's libraries.
    const linux_tests_module = b.createModule(.{
        .root_source_file = b.path("packages/ziggy/native/linux/src/tests.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{
        .name = "ziggy-shell-linux",
        .root_module = linux_tests_module,
    })).step);
    const windows_tests_module = b.createModule(.{
        .root_source_file = b.path("packages/ziggy/native/windows/src/tests.zig"),
        .target = b.graph.host,
        .optimize = optimize,
    });
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{
        .name = "ziggy-shell-windows",
        .root_module = windows_tests_module,
    })).step);

    // The example's core: a static library (with ziggy.h installed beside it) and, for Android, a shared one.
    const example_core_step = b.step("ziggy-example-core", "Build the Ziggy example's core as a library for the target");
    const example_module = b.createModule(.{
        .root_source_file = b.path("apps/ziggy-example/core/src/index.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    example_module.addImport("ziggy-core", core.module);
    example_module.addImport("page-files", try embedPage(b, core.module, "ziggy-core", "apps/ziggy-example/dist"));
    const static_library = b.addLibrary(.{
        .name = "ziggy_example",
        .root_module = example_module,
        .linkage = .static,
    });
    // The Xcode linker is not Zig's, so the compiler runtime (for example ___zig_probe_stack) must travel inside the archive.
    static_library.bundle_compiler_rt = true;
    example_core_step.dependOn(&b.addInstallArtifact(static_library, .{}).step);
    example_core_step.dependOn(&b.addInstallFileWithDir(b.path("packages/ziggy/core/src/lib/ziggy.h"), .header, "ziggy.h").step);
    if (target.result.abi.isAndroid()) {
        const shared_module = b.createModule(.{
            .root_source_file = b.path("apps/ziggy-example/core/src/index.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        shared_module.addImport("ziggy-core", core.module);
        shared_module.addImport("page-files", try embedPage(b, core.module, "ziggy-core", "apps/ziggy-example/dist"));
        const shared_library = b.addLibrary(.{
            .name = "ziggy_example",
            .root_module = shared_module,
            .linkage = .dynamic,
        });
        // Android 15 and later can run with 16 KiB memory pages, and a library is loaded only when its segments are aligned to the page
        // size, so they are aligned to the larger one.
        shared_library.link_z_max_page_size = 16384;
        example_core_step.dependOn(&b.addInstallArtifact(shared_library, .{}).step);
    }

    // The unit tests of the example's core.
    const example_for_tests = b.createModule(.{
        .root_source_file = b.path("apps/ziggy-example/core/src/handlers.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    example_for_tests.addImport("ziggy-core", test_core.module);
    example_for_tests.addImport("page-files", try embedPage(b, test_core.module, "ziggy-core", "apps/ziggy-example/dist"));
    const example_test_binary_step = b.step("test-binary-ziggy-example-core", "Build the unit test program of the Ziggy example's core and install it to test-bin without running it");
    try addDirectoryTests(b, test_step, "apps/ziggy-example/core", &.{
        .{ .name = "ziggy-core", .module = test_core.module },
        .{ .name = "ziggy-example-core", .module = example_for_tests },
    }, target, optimize, example_test_binary_step);

    try addZiggyExampleLinux(b, target, optimize, core, static_library);
    try addZiggyExampleWindows(b, target, optimize, core, static_library);
}

//
// The shared libraries the Linux shell links, by their full file names, which is what a program built against the development packages
// ends up needing at run time anyway. Nothing but the runtime libraries has to be installed.
//
const linux_runtime_libraries = [_][]const u8{
    "libglib-2.0.so.0",
    "libgobject-2.0.so.0",
    "libgio-2.0.so.0",
    "libgdk-3.so.0",
    "libgtk-3.so.0",
    "libjavascriptcoregtk-4.1.so.0",
    "libwebkit2gtk-4.1.so.0",
};

//
// Builds the Ziggy example's Linux shell, installed to zig-out/bin/ziggy-example by the `ziggy-example-linux` step. The shell is Zig
// that talks to GTK 3 and WebKitGTK 4.1 through their C headers, and to the core through ziggy.h. The built page (apps/ziggy-example/dist,
// made by `bun run bundle:ui`) is embedded in the executable, so the executable is the whole app.
//
fn addZiggyExampleLinux(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    core: IZiggyCore,
    example_core_library: *std.Build.Step.Compile,
) !void {
    const step = b.step("ziggy-example-linux", "Build the Ziggy example for Linux, installed to bin/ziggy-example");
    if (target.result.os.tag != .linux) {
        step.dependOn(&b.addFail("The ziggy-example-linux step builds for a Linux target.").step);
        return;
    }
    var runtime_library_paths: std.ArrayList([]const u8) = .empty;
    for (linux_runtime_libraries) |library| {
        const path = findRuntimeLibrary(b, library) catch {
            step.dependOn(&b.addFail(b.fmt("The runtime library {s} is not installed.", .{library})).step);
            return;
        };
        try runtime_library_paths.append(b.allocator, path);
    }

    const translate_c = b.addTranslateC(.{
        .root_source_file = b.path("packages/ziggy/native/linux/src/c.h"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    translate_c.addIncludePath(b.path("packages/ziggy/core/src/lib"));
    const shell_module = b.createModule(.{
        .root_source_file = b.path("packages/ziggy/native/linux/src/index.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    shell_module.addImport("c", translate_c.createModule());
    shell_module.addImport("ui-files", core.ui_files_module);
    for (runtime_library_paths.items) |path| {
        shell_module.addObjectFile(.{ .cwd_relative = path });
    }

    const module = b.createModule(.{
        .root_source_file = b.path("apps/ziggy-example/shells/linux/src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    module.addImport("ziggy-shell-linux", shell_module);
    module.addImport("ui-files", try embedPage(b, shell_module, "ziggy-shell-linux", "apps/ziggy-example/dist"));
    module.linkLibrary(example_core_library);
    const executable = b.addExecutable(.{
        .name = "ziggy-example",
        .root_module = module,
    });
    step.dependOn(&b.addInstallArtifact(executable, .{}).step);
}

//
// Builds the Ziggy example's Windows shell, installed to zig-out/ziggy-example/ziggy-example.exe by the `ziggy-example-windows` step. The
// shell is Zig that talks to Win32 and to WebView2 through their C headers. The executable is the whole app: the built page is embedded
// in it and WebView2's loader is linked into it. The page is expected in apps/ziggy-example/dist (bun run bundle:ui) and the loader's
// static library in apps/ziggy-example/webview2-sdk (the setup script), and the build fails when either is missing. The
// `ziggy-example-windows-check` step compiles the shell without linking it, for a machine that cannot link a Windows executable.
//
fn addZiggyExampleWindows(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    core: IZiggyCore,
    example_core_library: *std.Build.Step.Compile,
) !void {
    const step = b.step("ziggy-example-windows", "Build the Ziggy example for Windows, installed to ziggy-example/ziggy-example.exe");
    const check_step = b.step("ziggy-example-windows-check", "Compile the Ziggy example's Windows shell for type errors without linking");
    const compile_only = b.option(bool, "compile-only", "Compile the Windows shell without linking the WebView2 loader, to check it on a machine that cannot link") orelse false;
    if (target.result.os.tag != .windows) {
        const message = "The ziggy-example-windows steps build for a Windows target.";
        step.dependOn(&b.addFail(message).step);
        check_step.dependOn(&b.addFail(message).step);
        return;
    }
    const sdk_architecture = switch (target.result.cpu.arch) {
        .x86_64 => "x64",
        .aarch64 => "arm64",
        else => return error.UnsupportedArchitecture,
    };

    // The headers are translated for the -gnu ABI of the target's architecture, so that they come from the mingw headers Zig bundles.
    // With the -msvc target on a machine that has the Windows SDK, Zig would hand translate-c the SDK's own headers, which its C front
    // end cannot parse (MSVC extensions such as __ptr64 in basetsd.h). The two ABIs share the calling convention and struct layout on
    // Windows, so the declarations are the same, and the executable is still built and linked for the -msvc target.
    var translate_query = target.query;
    translate_query.abi = .gnu;
    const translate_c = b.addTranslateC(.{
        .root_source_file = b.path("packages/ziggy/native/windows/src/c.h"),
        .target = b.resolveTargetQuery(translate_query),
        .optimize = optimize,
        .link_libc = true,
    });
    translate_c.addIncludePath(b.path("packages/ziggy/core/src/lib"));
    translate_c.addIncludePath(b.path("apps/ziggy-example/webview2-sdk/include"));

    const shell_module = b.createModule(.{
        .root_source_file = b.path("packages/ziggy/native/windows/src/index.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    shell_module.addImport("c", translate_c.createModule());
    shell_module.addImport("ui-files", core.ui_files_module);
    shell_module.linkSystemLibrary("user32", .{});
    shell_module.linkSystemLibrary("kernel32", .{});
    shell_module.linkSystemLibrary("ole32", .{});
    shell_module.linkSystemLibrary("shell32", .{});
    shell_module.linkSystemLibrary("uuid", .{});
    // The WebView2 static loader reads the registry and writes event traces, which live in advapi32.
    shell_module.linkSystemLibrary("advapi32", .{});
    // Without the library the module still compiles, which is how a machine that cannot link a Windows executable checks the shell, but
    // nothing built from it links.
    if (!compile_only) {
        shell_module.addObjectFile(b.path(b.fmt("apps/ziggy-example/webview2-sdk/{s}/WebView2LoaderStatic.lib", .{sdk_architecture})));
    }

    const module = b.createModule(.{
        .root_source_file = b.path("apps/ziggy-example/shells/windows/src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    module.addImport("ziggy-shell-windows", shell_module);
    module.addImport("ui-files", try embedPage(b, shell_module, "ziggy-shell-windows", "apps/ziggy-example/dist"));
    module.linkLibrary(example_core_library);
    const executable = b.addExecutable(.{
        .name = "ziggy-example",
        .root_module = module,
    });
    executable.subsystem = .windows;
    // The windows subsystem keeps a console from opening, but its default entry point in the MSVC C runtime calls WinMain. Zig's main is
    // exported as the C main, so the entry point is the C runtime's one that calls main.
    executable.entry = .{ .symbol_name = "mainCRTStartup" };

    // Compiles the shell without linking it, for a machine that cannot link a Windows executable. The link needs Microsoft's toolchain
    // because the SDK's static loader is built with it.
    check_step.dependOn(&b.addObject(.{
        .name = "ziggy-example-check",
        .root_module = module,
    }).step);
    step.dependOn(&b.addInstallArtifact(executable, .{
        .dest_dir = .{
            .override = .{
                .custom = "ziggy-example",
            },
        },
        .pdb_dir = .disabled,
    }).step);
}

//
// Runs the unit test program under kcov, which writes a line-coverage report of the packages' own sources (not their tests or their
// dependencies) to the directory.
//
fn addCoverageRun(b: *std.Build, unit_test: *std.Build.Step.Compile, coverage_dir: []const u8) !*std.Build.Step.Run {
    var test_paths: std.ArrayList(u8) = .empty;
    for (packages) |package| {
        if (test_paths.items.len > 0) {
            try test_paths.append(b.allocator, ',');
        }
        try test_paths.appendSlice(b.allocator, b.pathFromRoot(b.fmt("packages-zig/{s}/src/test", .{package.name})));
    }
    const run = b.addSystemCommand(&.{
        "kcov",
        b.fmt("--include-path={s}", .{b.pathFromRoot("packages-zig")}),
        b.fmt("--exclude-path={s}", .{test_paths.items}),
        b.pathFromRoot(coverage_dir),
    });
    run.addArtifactArg(unit_test);
    return run;
}

//
// Makes a step that is part of the build but is not a step of its own on the command line: `test` depends on it and it depends on
// the tests of one part.
//
fn internalStep(b: *std.Build, name: []const u8) *std.Build.Step {
    const step = b.allocator.create(std.Build.Step) catch @panic("out of memory");
    step.* = std.Build.Step.init(.{
        .id = .custom,
        .name = name,
        .owner = b,
    });
    return step;
}
