const std = @import("std");
const aws_lc = @import("packages-zig/encryption-zig/aws/aws-lc.zig");
const aws_sdk = @import("packages-zig/storage-zig/aws/aws-sdk.zig");
const zlib_ng = @import("packages-zig/serialization-zig/zlib-ng/zlib-ng.zig");
const imagemagick = @import("packages-zig/media-tools-zig/imagemagick/imagemagick.zig");
const ffmpeg = @import("packages-zig/media-tools-zig/ffmpeg/ffmpeg.zig");
const android_libc = @import("packages-zig/android-libc.zig");
const apple_sdk = @import("packages-zig/apple-sdk.zig");
const translate_target = @import("packages-zig/translate-target.zig");
const ziggy_build = @import("ziggy");

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
    .{
        .name = "utils-zig",
        .dependencies = &.{},
        .link_libc = false,
    },
    .{
        .name = "fuzzy-match-zig",
        .dependencies = &.{},
        .link_libc = false,
    },
    .{
        .name = "lan-share-core-zig",
        .dependencies = &.{},
        .link_libc = false,
    },
    .{
        .name = "node-utils-zig",
        .dependencies = &.{"utils-zig"},
        .link_libc = true,
    },
    .{
        .name = "encryption-zig",
        .dependencies = &.{ "utils-zig", "node-utils-zig" },
        .link_libc = false,
    },
    .{
        .name = "serialization-zig",
        .dependencies = &.{"utils-zig"},
        .link_libc = false,
    },
    .{
        .name = "tools-zig",
        .dependencies = &.{ "utils-zig", "node-utils-zig", "serialization-zig" },
        .link_libc = false,
    },
    .{
        .name = "vault-zig",
        .dependencies = &.{ "utils-zig", "node-utils-zig" },
        .link_libc = false,
    },
    .{
        .name = "storage-zig",
        .dependencies = &.{ "utils-zig", "node-utils-zig", "encryption-zig" },
        .link_libc = false,
    },
    .{
        .name = "merkle-tree-zig",
        .dependencies = &.{ "utils-zig", "serialization-zig", "storage-zig" },
        .link_libc = false,
    },
    .{
        .name = "bdb-zig",
        .dependencies = &.{ "utils-zig", "serialization-zig", "storage-zig", "merkle-tree-zig" },
        .link_libc = false,
    },
    .{
        .name = "lan-share-network-zig",
        .dependencies = &.{ "utils-zig", "node-utils-zig", "encryption-zig" },
        .link_libc = true,
    },
    .{
        .name = "mcp-zig",
        .dependencies = &.{ "utils-zig", "node-utils-zig", "serialization-zig", "bdb-zig" },
        .link_libc = false,
    },
    .{
        .name = "api-zig",
        .dependencies = &.{ "utils-zig", "storage-zig", "serialization-zig", "vault-zig", "lan-share-core-zig", "node-utils-zig", "encryption-zig", "bdb-zig" },
        .link_libc = false,
    },
    .{
        .name = "node-api-zig",
        .dependencies = &.{ "lan-share-network-zig", "utils-zig", "node-utils-zig", "encryption-zig", "serialization-zig", "storage-zig", "merkle-tree-zig", "bdb-zig", "api-zig", "vault-zig", "tools-zig" },
        .link_libc = false,
    },
    .{
        .name = "rest-api-zig",
        .dependencies = &.{ "utils-zig", "node-utils-zig", "node-api-zig" },
        .link_libc = false,
    },
    .{
        .name = "config-zig",
        .dependencies = &.{},
        .link_libc = false,
    },
    .{
        .name = "mobile-worker-zig",
        .dependencies = &.{ "utils-zig", "api-zig", "node-api-zig" },
        .link_libc = false,
    },
    .{
        .name = "media-tools-zig",
        .dependencies = &.{ "utils-zig", "node-utils-zig" },
        .link_libc = true,
    },
    .{
        .name = "photosphere-core",
        .dependencies = &.{ "utils-zig", "node-utils-zig", "config-zig", "mobile-worker-zig", "tools-zig", "media-tools-zig", "encryption-zig", "storage-zig", "vault-zig", "serialization-zig", "merkle-tree-zig", "bdb-zig", "mcp-zig", "api-zig", "node-api-zig" },
        .link_libc = true,
    },
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
    // Whether the test hooks (the test control connection) are built into the apps. Never for a release.
    const test_hooks = b.option(bool, "test-hooks", "Build the test hooks (the test control connection) into the app (never for a release)") orelse false;
    // Whether the Windows shells are compiled without linking WebView2's loader, to check them on a machine that cannot link.
    const compile_only = b.option(bool, "compile-only", "Compile the Windows shell without linking the WebView2 loader, to check it on a machine that cannot link") orelse false;
    // Whether the desktop executables leave out their debug information. Only the release packages do: a dev or test build keeps it, so
    // a panic there prints where it happened.
    const strip = b.option(bool, "strip", "Leave the debug information out of the desktop executables (for a release)") orelse false;
    // ReleaseSafe by default: the tests keep the safety checks, and the work of the database and storage tests is several times
    // slower in Debug.
    const optimize = b.option(std.builtin.OptimizeMode, "optimize", "Prioritize performance, safety, or binary size (default: ReleaseSafe)") orelse .ReleaseSafe;
    // The media libraries have steps of their own for every target, which build one library by itself (see packages-zig/media-tools-zig).
    // The files FFmpeg needs for a target are made by a script (ffmpeg/generate-config.sh) that needs zlib built for the target first, and
    // FFmpeg's steps and the packages need those files, so the script asks for the zlib step alone.
    const zlib_only = b.option(bool, "zlib-only", "Register only the step that builds zlib, which is what the script that makes FFmpeg's files uses") orelse false;
    try addMediaToolSteps(b, target, zlib_only);
    if (zlib_only) {
        return;
    }
    // The packages, the CLI and their tests are built for the machine running the build only (Windows, iOS and Android are cross builds of Photosphere's core only, below): the AWS SDK for C builds for Linux,
    // Windows, iOS and macOS (iOS with the SDK of Xcode, macOS natively), and zlib-ng for x86_64 and aarch64 on Windows. For any other
    // target the steps of Photosphere say why they cannot be built. The steps of the packages and the tests are not registered, so asking
    // for one fails with an unknown step instead of building a partial set.
    const host = b.graph.host.result;
    const is_host_platform = target.result.os.tag == host.os.tag and target.result.cpu.arch == host.cpu.arch and target.result.abi == host.abi;
    const packages_supported = is_host_platform and switch (target.result.os.tag) {
        .linux, .windows => true,
        .macos => target.query.isNativeOs() and target.query.isNativeAbi(),
        else => false,
    };
    // iOS, and macOS for a target that is not the native one (the Photosphere App's core is built for the macOS 11.0 its Xcode project
    // targets), need the Apple SDK, which a machine without Xcode lacks: there the Photosphere steps say why they cannot be built.
    const is_cross_core_target = ((target.result.os.tag == .ios or target.result.os.tag == .macos) and apple_sdk.findSdk(b, target) != null) or (target.result.os.tag == .windows and (target.result.cpu.arch == .x86_64 or target.result.cpu.arch == .aarch64));
    if (!target.result.abi.isAndroid() and !packages_supported and !is_cross_core_target) {
        try addPhotosphereUnavailable(b, target);
        return;
    }
    // Ziggy, from the dependency named "ziggy" in build.zig.zon, with the test hooks when the app is built with them. The packages, the
    // CLI and the app all use this one.
    const ziggy = ziggy_build.dependency(b, target, optimize, test_hooks);
    // Null means a lazy dependency is being fetched first: the build runs again once it has been, and this run registers nothing.
    const modules = (try addPackageModules(b, target, optimize, ziggy.module)) orelse return;
    if (!packages_supported) {
        // An Android, iOS or Windows build here is a cross build of Photosphere's core only: the packages are made for the target, but
        // their tests and the CLI are not, since none can run on the build machine.
        try addPhotosphere(b, target, optimize, compile_only, strip, ziggy, modules);
        return;
    }

    const test_step = b.step("test", "Run every Zig test: the unit tests of the packages and the tests of the CLI");
    const test_packages_step = internalStep(b, "unit tests of the packages");
    const test_cli_step = internalStep(b, "tests of the CLI");
    test_step.dependOn(test_packages_step);
    test_step.dependOn(test_cli_step);
    const stand_ins = addStandIns(b, target, optimize);
    // The unit tests run Photosphere's core with Ziggy's test hooks compiled in. Every module of the test program must import the same
    // Ziggy, so without the test hooks for the app the packages are made a second time over Ziggy with them.
    const test_modules = if (test_hooks) modules else (try addPackageModules(b, target, optimize, ziggy_build.dependency(b, target, optimize, true).module)) orelse return;
    try addUnitTests(b, test_packages_step, test_modules, target, optimize, stand_ins);
    // The tests inside the build helper files (they are compiled by the build itself, so they are not under a package's src/test).
    const apple_sdk_tests = b.addTest(.{
        .name = "apple-sdk",
        .root_module = b.createModule(.{
            .root_source_file = b.path("packages-zig/apple-sdk.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    test_packages_step.dependOn(&b.addRunArtifact(apple_sdk_tests).step);
    const translate_target_tests = b.addTest(.{
        .name = "translate-target",
        .root_module = b.createModule(.{
            .root_source_file = b.path("packages-zig/translate-target.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    test_packages_step.dependOn(&b.addRunArtifact(translate_target_tests).step);
    try addOwnProcessTests(b, test_packages_step, modules, target, optimize, stand_ins);
    try addStorageIntegrationTests(b, modules, target, optimize);
    try addCli(b, test_cli_step, modules, target, optimize);
    try addPhotosphere(b, target, optimize, compile_only, strip, ziggy, modules);

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
// Creates the module of every package over the Ziggy core given, with the libraries the packages need, and returns them by name, with
// Ziggy's core as "ziggy-core". Returns null while a lazy dependency is being fetched.
//
fn addPackageModules(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    ziggy_core: *std.Build.Module,
) !?std.StringHashMap(*std.Build.Module) {
    var modules = std.StringHashMap(*std.Build.Module).init(b.allocator);
    try modules.put("ziggy-core", ziggy_core);
    var crypto: ?*std.Build.Step.Compile = null;
    var ssl: ?*std.Build.Step.Compile = null;
    // zlib-ng, built once for the packages that use it (serialization-zig and the media tools).
    var zlib: ?zlib_ng.IZlibNg = null;

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
        // Ziggy's core, whose task queue the packages queue and run their tasks with. Every module of a program must import the same
        // one, or a registry in it would be two.
        module.addImport("ziggy-core", ziggy_core);
        try modules.put(package.name, module);

        if (std.mem.eql(u8, package.name, "encryption-zig")) {
            // aws-lc's libcrypto, whose functions node-crypto.zig calls and which the AWS SDK for C links as well, and libssl
            // over it for lan-share-network-zig.
            crypto = try aws_lc.build(b, target, b.dependency("aws-lc", .{}));
            module.linkLibrary(crypto.?);
            ssl = try aws_lc.buildSsl(b, target, b.dependency("aws-lc", .{}), crypto.?);
            module.addImport("openssl", try translateHeader(b, target, crypto.?, encryption_openssl_header));
        }
        if (std.mem.eql(u8, package.name, "serialization-zig")) {
            // zlib-ng, which gzip compression and decompression bind to.
            zlib = try zlib_ng.buildZlibNg(b, target);
            try zlib_ng.addZlibNg(b, module, target, zlib.?);
        }
        if (std.mem.eql(u8, package.name, "media-tools-zig")) {
            // ImageMagick and FFmpeg, built over the same zlib-ng as serialization-zig's, which the program has one copy of.
            try imagemagick.addImageMagick(b, module, target, zlib.?);
            try ffmpeg.addFfmpeg(b, module, target, zlib.?);
        }
        if (std.mem.eql(u8, package.name, "storage-zig")) {
            // The AWS SDK for C, which the S3 client binds to, over the libcrypto that encryption-zig builds. False means a lazy
            // dependency is being fetched first.
            if (!try aws_sdk.addAwsSdk(b, module, target, crypto.?)) {
                return null;
            }
        }
        if (std.mem.eql(u8, package.name, "lan-share-network-zig")) {
            module.linkLibrary(ssl.?);
            if (target.result.os.tag == .windows) {
                module.linkSystemLibrary("ws2_32", .{});
            }
            module.addImport("openssl", try translateHeader(b, target, crypto.?, lan_share_openssl_header));
        }
    }
    return modules;
}

//
// Translates C headers that include libcrypto's to a Zig module. Translated without optimization: in the optimized modes the
// MinGW headers define fortified inline wrappers of memset and friends, which translate-c turns into Zig that does not
// compile. The declarations are the same.
//
fn translateHeader(b: *std.Build, target: std.Build.ResolvedTarget, crypto: *std.Build.Step.Compile, header: []const u8) !*std.Build.Module {
    const translate_c = b.addTranslateC(.{
        .root_source_file = b.addWriteFiles().add("openssl.h", header),
        .target = translate_target.translateTarget(b, target),
        .optimize = .Debug,
    });
    translate_c.addIncludePath(crypto.getEmittedIncludeTree());
    try android_libc.addLibcIncludes(b, translate_c, target);
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
    const only_files = b.option([]const []const u8, "test-file", "Only run the tests of this file (for example bdb-zig/merkle-tree.test.zig); pass it more than once for several files");
    var test_root_source: std.ArrayList(u8) = .empty;
    try test_root_source.appendSlice(b.allocator, "test {\n");
    for (packages) |package| {
        _ = test_files.addCopyDirectory(b.path(b.fmt("packages-zig/{s}/src", .{package.name})), b.fmt("{s}/src", .{package.name}), .{});
        var test_dir = try b.build_root.handle.openDir(b.graph.io, b.fmt("packages-zig/{s}/src/test", .{package.name}), .{
            .iterate = true,
        });
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
            if (only_files) |wanted_files| {
                const package_path = b.fmt("{s}/{s}", .{ package.name, entry.path });
                var is_wanted = false;
                for (wanted_files) |wanted_file| {
                    if (std.mem.eql(u8, wanted_file, package_path)) {
                        is_wanted = true;
                    }
                }
                if (!is_wanted) {
                    continue;
                }
            }
            // The walker gives the path with the system's separator, and a Windows backslash in a Zig string starts an escape, so the
            // import is written with the forward slashes an import path takes on every system.
            const import_path = try b.allocator.dupe(u8, entry.path);
            std.mem.replaceScalar(u8, import_path, std.fs.path.sep, '/');
            try test_root_source.appendSlice(b.allocator, b.fmt("    _ = @import(\"{s}/src/test/{s}\");\n", .{ package.name, import_path }));
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
        // The tests of photosphere-core import its files by path.
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
    var vault_test_dir = try b.build_root.handle.openDir(b.graph.io, "packages-zig/vault-zig/src/test", .{
        .iterate = true,
    });
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
    "ziggy-core",
    "serialization-zig",
    "merkle-tree-zig",
    "bdb-zig",
    "mcp-zig",
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
    var test_dir = try b.build_root.handle.openDir(b.graph.io, "apps/cli-zig/src/test", .{
        .iterate = true,
    });
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

    // The program the Windows `psi bug` tests put where `psi bug` looks for PowerShell, so that no browser is opened (installed to
    // zig-out/test-bin, not zig-out/bin: it is not shipped). It imports nothing from the CLI and runs no CLI code.
    const opener_recorder = b.addExecutable(.{
        .name = "opener-recorder",
        .root_module = b.createModule(.{
            .root_source_file = b.path("apps/cli-zig/src/test/drivers/opener-recorder.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const install_opener_recorder = b.addInstallArtifact(opener_recorder, .{
        .dest_dir = .{
            .override = .{
                .custom = "test-bin",
            },
        },
    });
    run_test.step.dependOn(&install_opener_recorder.step);
    test_step.dependOn(&run_test.step);
}

//
// Builds Photosphere on Ziggy: its core as a library for the target, with its dev mode, and its Linux and Windows shells. The packages
// Photosphere's core is made of are built for the machine running the build, and cross built for Android, iOS and Windows, so for any
// other target addPhotosphereUnavailable registers the steps with a message that says so. The app's core, photosphere-core and every
// package import the same Ziggy, the one the packages were made with.
//
fn addPhotosphere(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    compile_only: bool,
    strip: bool,
    ziggy: ziggy_build.IZiggy,
    modules: std.StringHashMap(*std.Build.Module),
) !void {
    const libraries = try ziggy_build.addAppCore(b, ziggy, .{
        .name = "photosphere",
        .title = "Photosphere",
        .root_source_file = "apps/photosphere/core/src/index.zig",
        .ui_directory = photosphere_page_directory,
        .imports = &.{
            .{
                .name = "photosphere-core",
                .module = modules.get("photosphere-core").?,
            },
        },
    }, target, optimize);
    if (libraries.shared_library) |shared_library| {
        // aws-c-common writes its logs to Android's log (CMake: PLATFORM_LIBS log), which is in the C library's directory. It is linked
        // here and not by aws-c-common's static library, which would archive the system library as a member.
        shared_library.root_module.addLibraryPath(.{
            .cwd_relative = try android_libc.libcLibraryDirectory(b),
        });
        shared_library.root_module.linkSystemLibrary("log", .{});
        // Zig's own linker, which a Debug build uses by default, accesses s2n-tls' hidden thread-local variables in the initial-exec
        // model, and Android refuses to load a library that does ("TLS symbol "(null)" in dlopened ..."). LLD, which the release
        // builds use, does not, so every build of the library links with it, and is compiled by LLVM, which LLD needs.
        shared_library.use_llvm = true;
        shared_library.use_lld = true;
    }

    const photosphere_app: ziggy_build.IShellApp = .{
        .name = "photosphere",
        .title = "Photosphere",
        .directory = "apps/photosphere",
        .linux_icon = "apps/photosphere/icons/photosphere-512.png",
        .windows_resource = "apps/photosphere/shells/windows/photosphere.rc",
    };
    try ziggy_build.addLinuxShell(b, photosphere_app, strip, target, optimize, ziggy, libraries.static_library);
    try ziggy_build.addWindowsShell(b, photosphere_app, compile_only, strip, target, optimize, ziggy, libraries.static_library);
}

//
// The directory the page of Photosphere's app is built into (`bun run bundle:ui` in apps/photosphere), which the core embeds and serves to every shell.
//
const photosphere_page_directory = "apps/photosphere-frontend/dist";

//
// Registers the steps that build one media library by itself as a static library for the target, so a library can be built and
// checked on its own (`zig build imagemagick -Dtarget=<target>`): ImageMagick (with libjpeg, libpng and zlib), FFmpeg (with zlib), and
// zlib-ng with its headers (what FFmpeg's configure is pointed at). For a target one cannot be built for, the step says why.
//
fn addMediaToolSteps(b: *std.Build, target: std.Build.ResolvedTarget, zlib_only: bool) !void {
    const zlib_step = b.step("zlib", "Build zlib-ng as a static library, installed with its headers, for the target");
    const imagemagick_step = b.step("imagemagick", "Build ImageMagick (with libjpeg, libpng and zlib) as a static library for the target");
    const ffmpeg_step = b.step("ffmpeg", "Build FFmpeg (with the ffmpeg and ffprobe programs compiled in, and zlib) as a static library for the target");
    if (imagemagick.zlibUnsupportedReason(b, target)) |reason| {
        zlib_step.dependOn(&b.addFail(reason).step);
        imagemagick_step.dependOn(&b.addFail(imagemagick.unsupportedReason(b, target).?).step);
        ffmpeg_step.dependOn(&b.addFail(ffmpeg.unsupportedReason(b, target).?).step);
        return;
    }
    const zlib = try zlib_ng.buildZlibNg(b, target);
    zlib_step.dependOn(&b.addInstallArtifact(zlib.library, .{}).step);
    zlib_step.dependOn(&b.addInstallDirectory(.{
        .source_dir = zlib.include_directory,
        .install_dir = .prefix,
        .install_subdir = "include",
    }).step);
    if (zlib_only) {
        return;
    }
    if (imagemagick.unsupportedReason(b, target)) |reason| {
        imagemagick_step.dependOn(&b.addFail(reason).step);
    }
    else {
        const library = try imagemagick.buildImageMagick(b, target, zlib);
        imagemagick_step.dependOn(&b.addInstallArtifact(library.library, .{}).step);
    }
    if (ffmpeg.unsupportedReason(b, target)) |reason| {
        ffmpeg_step.dependOn(&b.addFail(reason).step);
    }
    else {
        const library = try ffmpeg.buildFfmpeg(b, target, zlib);
        ffmpeg_step.dependOn(&b.addInstallArtifact(library.library, .{}).step);
    }
}

//
// Registers Photosphere's steps for a target its core cannot be built for, so asking for one says why instead of reporting an unknown
// step. The packages Photosphere's core is made of include the AWS SDK for C and aws-lc, which are built for Linux, Windows, macOS and iOS,
// macOS natively on a Mac and iOS with the SDK of Xcode.
//
fn addPhotosphereUnavailable(b: *std.Build, target: std.Build.ResolvedTarget) !void {
    const message = if (target.result.os.tag == .ios)
        b.fmt("Photosphere's core for iOS needs Apple's {s} SDK, which comes with Xcode on a Mac and is found with `xcrun --sdk {s} --show-sdk-path`. It was not found here. It holds the AWS SDK for C and aws-lc, whose Apple sources include headers of that SDK, which Zig does not ship. Build for iOS on a Mac with Xcode installed. See docs/aws-sdk.md.", .{ apple_sdk.sdkName(target.result.os.tag, target.result.abi).?, apple_sdk.sdkName(target.result.os.tag, target.result.abi).? })
    else if (target.result.os.tag == .macos)
        "Photosphere's core for macOS can only be built on a Mac: it holds the AWS SDK for C and aws-lc, whose Apple sources include the Security, Network, CoreFoundation and CoreServices headers of the macOS SDK, which comes with Xcode or its Command Line Tools and is found with `xcrun --sdk macosx --show-sdk-path`. It was not found here."
    else
        "Photosphere's core is built for the machine running the build, for Windows (x86_64 and aarch64), for iOS (on a Mac with Xcode) and for Android (with the NDK's C library as a libc file). See docs/aws-sdk.md.";
    for ([_][]const u8{ "photosphere-core", "photosphere-linux", "photosphere-windows", "photosphere-windows-check" }) |name| {
        const step = b.step(name, "Build Photosphere (only for the machine running the build)");
        step.dependOn(&b.addFail(message).step);
    }
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
