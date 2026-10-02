const std = @import("std");
const cli = @import("cli-zig");
const tools = @import("tools-zig");
const helpers = @import("test-helpers.zig");

test "ensureMediaProcessingTools returns when every tool is available" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Without the tools ensureMediaProcessingTools exits the process: fail instead, saying what is missing.
    // The detection is forgotten first, because Image looks its commands up on PATH once and remembers the
    // answer for the rest of the process, so a test that ran before this one and replaced the environment can
    // leave it believing no ImageMagick is installed when one is.
    tools.Image.resetInitialization();
    const status = try tools.verifyTools(allocator, std.testing.io);
    if (!status.allAvailable) {
        std.debug.print("This test needs ImageMagick and ffmpeg installed. Missing: {s}\n", .{try std.mem.join(allocator, ", ", status.missingTools)});
        return error.RequiredToolsMissing;
    }
    try cli.ensure_tools.ensureMediaProcessingTools(allocator, std.testing.io, true);
}

test "ensureMediaProcessingTools reports the missing tools and exits when none are on the PATH" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root = try helpers.makeTempDir(allocator, "ensure-tools-missing");
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    const environment = try helpers.cliEnvironment(allocator, root);

    // A PATH holding only an empty directory: psi finds none of the tools.
    const emptyBinDir = try std.fs.path.join(allocator, &.{ root, "empty-bin" });
    try std.Io.Dir.cwd().createDirPath(std.testing.io, emptyBinDir);
    try environment.put("PATH", emptyBinDir);

    // verify checks the tools (non-interactively, with --yes) before it looks at the database.
    const psiPath = try std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, helpers.psi_path, allocator);
    const result = try helpers.runCli(allocator, &.{ psiPath, "verify", "--db", root, "--yes" }, environment);

    try std.testing.expectEqual(@as(u8, 1), result.exitCode);
    try std.testing.expect(std.mem.indexOf(u8, result.stderr, "Required media processing tools are not available.") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "Missing tools: ImageMagick, ffprobe, ffmpeg") != null);
}
