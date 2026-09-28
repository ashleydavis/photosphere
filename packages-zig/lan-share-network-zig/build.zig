const std = @import("std");

//
// The name of the module exposed by this package.
//
const module_name = "lan-share-network-zig";

//
// Names of the packages this package depends on.
//
const dependency_names = [_][]const u8{ "utils-zig", "node-utils-zig", "encryption-zig" };

//
// The name the module translated from the libssl and libcrypto headers is imported under.
//
const openssl_module_name = "openssl";

//
// The libssl and libcrypto headers the HTTPS server and client use, translated to Zig as the "openssl" module.
//
const openssl_header =
    \\#include <openssl/bio.h>
    \\#include <openssl/err.h>
    \\#include <openssl/evp.h>
    \\#include <openssl/pem.h>
    \\#include <openssl/ssl.h>
    \\#include <openssl/x509.h>
    \\
;

//
// Builds the module over encryption-zig's libssl and libcrypto, and registers a test step that runs every file in
// src/test.
//
pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const module = b.addModule(module_name, .{
        .root_source_file = b.path("src/index.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    for (dependency_names) |dependency_name| {
        const dependency = b.dependency(dependency_name, .{ .target = target, .optimize = optimize });
        module.addImport(dependency_name, dependency.module(dependency_name));
    }
    const encryption = b.dependency("encryption-zig", .{ .target = target, .optimize = optimize });
    const ssl = encryption.artifact("ssl");
    const crypto = encryption.artifact("crypto");
    module.linkLibrary(ssl);
    if (target.result.os.tag == .windows) {
        module.linkSystemLibrary("ws2_32", .{});
    }
    // Translated without optimization, like encryption-zig's "openssl" module (the MinGW headers' fortified inline
    // wrappers do not translate in the optimized modes).
    const translate_c = b.addTranslateC(.{
        .root_source_file = b.addWriteFiles().add("openssl.h", openssl_header),
        .target = target,
        .optimize = .Debug,
    });
    translate_c.addIncludePath(crypto.getEmittedIncludeTree());
    const openssl_module = translate_c.createModule();
    module.addImport(openssl_module_name, openssl_module);

    const test_step = b.step("test", "Run unit tests");
    // Every test file is compiled into one test program, whose root imports each of them. The src directory is
    // copied next to the generated root so that the imports of the tests resolve as they do in src/test.
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
    const unit_test = b.addTest(.{ .root_module = test_module });
    const run_test = b.addRunArtifact(unit_test);
    run_test.setCwd(b.path("."));
    test_step.dependOn(&run_test.step);
}
