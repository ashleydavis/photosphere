const std = @import("std");
const aws_lc = @import("aws/aws-lc.zig");

//
// The name of the module exposed by this package.
//
const module_name = "encryption-zig";

//
// Names of the packages this package depends on.
//
const dependency_names = [_][]const u8{"utils-zig"};

//
// The name the module translated from the libcrypto headers is imported under (by src/lib/node-crypto.zig and by
// the tests).
//
const openssl_module_name = "openssl";

//
// The libcrypto headers node-crypto.zig uses, translated to Zig as the "openssl" module.
//
const openssl_header =
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
// Builds aws-lc's libcrypto and the module over it, and registers a test step that runs every file in src/test.
// libcrypto is installed as the "crypto" artifact so that storage-zig links the same library into the AWS SDK for C,
// and libssl as the "ssl" artifact.
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
    const crypto = try aws_lc.build(b, target, b.dependency("aws-lc", .{}));
    b.installArtifact(crypto);
    module.linkLibrary(crypto);
    // libssl, over the same libcrypto, installed as the "ssl" artifact for lan-share-network-zig (its HTTPS server
    // and client). This package does not use it.
    const ssl = try aws_lc.buildSsl(b, target, b.dependency("aws-lc", .{}), crypto);
    b.installArtifact(ssl);
    // Translated without optimization: in the optimized modes the MinGW headers define fortified inline wrappers of
    // memset and friends, which translate-c turns into Zig that does not compile. The declarations are the same.
    const translate_c = b.addTranslateC(.{
        .root_source_file = b.addWriteFiles().add("openssl.h", openssl_header),
        .target = target,
        .optimize = .Debug,
    });
    translate_c.addIncludePath(crypto.getEmittedIncludeTree());
    const openssl_module = translate_c.createModule();
    module.addImport(openssl_module_name, openssl_module);

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
        try test_root_source.appendSlice(b.allocator, b.fmt("    _ = @import(\"{s}\");\n", .{entry.path}));
    }
    try test_root_source.appendSlice(b.allocator, "}\n");
    const test_module = b.createModule(.{
        .root_source_file = test_files.add("src/test/all-tests.zig", test_root_source.items),
        .target = target,
        .optimize = optimize,
    });
    test_module.addImport(module_name, module);
    test_module.addImport(openssl_module_name, openssl_module);
    for (dependency_names) |dependency_name| {
        const dependency = b.dependency(dependency_name, .{ .target = target, .optimize = optimize });
        test_module.addImport(dependency_name, dependency.module(dependency_name));
    }
    // The directory to write a kcov line-coverage report of the unit tests to (see docs/zig-test-coverage.md).
    // The tests are then compiled with the LLVM backend, whose debug info kcov reads, and run under kcov.
    const coverage_dir = b.option([]const u8, "coverage", "Write a kcov line-coverage report of the unit tests to this directory");
    const unit_test = b.addTest(.{ .root_module = test_module, .use_llvm = if (coverage_dir != null) true else null });
    const run_test = if (coverage_dir) |directory| addCoverageRun(b, unit_test, directory) else b.addRunArtifact(unit_test);
    run_test.setCwd(b.path("."));
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
