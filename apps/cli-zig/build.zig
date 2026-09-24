const std = @import("std");

//
// The name of the module exposed by this package.
//
const module_name = "cli-zig";

//
// Names of the packages this package depends on.
//
const dependency_names = [_][]const u8{
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
};

//
// Builds the module, the `psi` executable (installed to zig-out/bin/psi) and registers a test step
// that runs every file in src/test.
// The default optimize mode is ReleaseSafe because RSA key generation is too slow in Debug.
//
pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.option(std.builtin.OptimizeMode, "optimize", "Prioritize performance, safety, or binary size (default: ReleaseSafe)") orelse .ReleaseSafe;

    //
    // The absolute path of the TypeScript CLI entry point, used to delegate the commands that are not ported.
    //
    const ts_cli_path = try std.fs.path.resolve(b.allocator, &.{ b.build_root.path orelse ".", "..", "cli", "index.ts" });
    const build_options = b.addOptions();
    build_options.addOption([]const u8, "ts_cli_path", ts_cli_path);
    const build_options_module = build_options.createModule();

    const module = b.addModule(module_name, .{
        .root_source_file = b.path("index.zig"),
        .target = target,
        .optimize = optimize,
    });
    module.addImport("build_options", build_options_module);
    for (dependency_names) |dependency_name| {
        const dependency = b.dependency(dependency_name, .{ .target = target, .optimize = optimize });
        module.addImport(dependency_name, dependency.module(dependency_name));
    }

    const executable = b.addExecutable(.{
        .name = "psi",
        .root_module = module,
    });
    b.installArtifact(executable);

    const test_file = b.option([]const u8, "test-file", "Only run the tests of this file (e.g. prompts.test.zig)");
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(b.getInstallStep());
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
        const test_module = b.createModule(.{
            .root_source_file = b.path(b.fmt("src/test/{s}", .{entry.path})),
            .target = target,
            .optimize = optimize,
        });
        test_module.addImport(module_name, module);
        test_module.addImport("build_options", build_options_module);
        for (dependency_names) |dependency_name| {
            const dependency = b.dependency(dependency_name, .{ .target = target, .optimize = optimize });
            test_module.addImport(dependency_name, dependency.module(dependency_name));
        }
        const unit_test = b.addTest(.{ .root_module = test_module });
        const run_test = b.addRunArtifact(unit_test);
        run_test.setCwd(b.path("."));
        run_test.step.dependOn(b.getInstallStep());
        test_step.dependOn(&run_test.step);
    }
}
