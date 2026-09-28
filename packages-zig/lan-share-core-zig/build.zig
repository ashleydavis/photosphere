const std = @import("std");

//
// The name of the module exposed by this package.
//
const module_name = "lan-share-core-zig";

//
// Names of the packages this package depends on.
//
const dependency_names = [_][]const u8{};

//
// Builds the module and registers a test step that compiles it.
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
    // The package has no tests of its own (the TypeScript tests of lan-share-core cover importShareSecrets, which is
    // not ported), so the test step compiles the module and runs the tests it declares, which is none.
    const unit_test = b.addTest(.{ .root_module = module });
    const run_test = b.addRunArtifact(unit_test);
    test_step.dependOn(&run_test.step);
}
