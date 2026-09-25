const std = @import("std");
const cli = @import("cli-zig");
const helpers = @import("test-helpers.zig");
const delegate = cli.delegate;

test "buildDelegateArgv runs the TypeScript entry point with bun" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const argv = try delegate.buildDelegateArgv(arena.allocator(), "/repo/apps/cli/index.ts", &.{ "summary", "--db", "x y" });
    try std.testing.expectEqual(@as(usize, 5), argv.len);
    try std.testing.expectEqualStrings("bun", argv[0]);
    try std.testing.expectEqualStrings("/repo/apps/cli/index.ts", argv[1]);
    try std.testing.expectEqualStrings("summary", argv[2]);
    try std.testing.expectEqualStrings("x y", argv[4]);
}

test "the TypeScript entry point path is absolute and exists" {
    try std.testing.expect(std.fs.path.isAbsolute(delegate.ts_cli_path));
    try std.testing.expect(std.mem.endsWith(u8, delegate.ts_cli_path, "apps/cli/index.ts"));
    _ = try std.Io.Dir.cwd().statFile(std.testing.io, delegate.ts_cli_path, .{});
}

test "exitCodeForTerm uses the exit code or 128 plus the signal" {
    try std.testing.expectEqual(@as(u8, 0), delegate.exitCodeForTerm(.{ .exited = 0 }));
    try std.testing.expectEqual(@as(u8, 3), delegate.exitCodeForTerm(.{ .exited = 3 }));
    try std.testing.expectEqual(@as(u8, 130), delegate.exitCodeForTerm(.{ .signal = .INT }));
    try std.testing.expectEqual(@as(u8, 143), delegate.exitCodeForTerm(.{ .signal = .TERM }));
    try std.testing.expectEqual(@as(u8, 1), delegate.exitCodeForTerm(.{ .unknown = 7 }));
}

//
// The result of running the built psi binary.
//
const RunResult = struct {
    // The exit code.
    exitCode: u8,

    // What the binary wrote to stdout.
    stdout: []const u8,

    // What the binary wrote to stderr.
    stderr: []const u8,
};

//
// Runs the built binary (zig-out/bin/psi, psi.exe on Windows) with the arguments from the apps/cli directory.
//
fn runPsi(allocator: std.mem.Allocator, args: []const []const u8) !RunResult {
    const psiPath = try std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, helpers.psi_path, allocator);
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.append(allocator, psiPath);
    try argv.appendSlice(allocator, args);
    const cliDir = try std.Io.Dir.cwd().openDir(std.testing.io, "../cli", .{});
    defer cliDir.close(std.testing.io);
    const result = try std.process.run(allocator, std.testing.io, .{
        .argv = argv.items,
        .cwd = .{ .dir = cliDir },
    });
    return .{ .exitCode = delegate.exitCodeForTerm(result.term), .stdout = result.stdout, .stderr = result.stderr };
}

test "psi --version is delegated to the TypeScript CLI" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // Delegated commands run in Bun; skip where Bun cannot be spawned.
    if (!helpers.bunAvailable(arena.allocator())) {
        return error.SkipZigTest;
    }
    const result = try runPsi(arena.allocator(), &.{"--version"});
    try std.testing.expectEqual(@as(u8, 0), result.exitCode);
    try std.testing.expectEqualStrings("dev\n", result.stdout);
}

test "psi summary --help is delegated to the TypeScript CLI" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // Delegated commands run in Bun; skip where Bun cannot be spawned.
    if (!helpers.bunAvailable(arena.allocator())) {
        return error.SkipZigTest;
    }
    const result = try runPsi(arena.allocator(), &.{ "summary", "--help" });
    try std.testing.expectEqual(@as(u8, 0), result.exitCode);
    try std.testing.expect(std.mem.startsWith(u8, result.stdout, "Usage: psi summary|sum [options]"));
}

test "the exit code of a delegated command is passed through" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // Delegated commands run in Bun; skip where Bun cannot be spawned.
    if (!helpers.bunAvailable(arena.allocator())) {
        return error.SkipZigTest;
    }
    const result = try runPsi(arena.allocator(), &.{"no-such-command"});
    try std.testing.expectEqual(@as(u8, 1), result.exitCode);
    try std.testing.expect(std.mem.indexOf(u8, result.stderr, "unknown command 'no-such-command'") != null);
}

test "psi replicate reports unknown options like commander" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try runPsi(arena.allocator(), &.{ "rep", "--flul" });
    try std.testing.expectEqual(@as(u8, 1), result.exitCode);
    try std.testing.expectEqualStrings("error: unknown option '--flul'\n(Did you mean --full?)\n", result.stderr);
    try std.testing.expectEqualStrings("", result.stdout);
}

test "psi verify --help is delegated to the TypeScript CLI" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // Delegated commands run in Bun; skip where Bun cannot be spawned.
    if (!helpers.bunAvailable(arena.allocator())) {
        return error.SkipZigTest;
    }
    const result = try runPsi(arena.allocator(), &.{ "verify", "--help" });
    try std.testing.expectEqual(@as(u8, 0), result.exitCode);
    try std.testing.expect(std.mem.startsWith(u8, result.stdout, "Usage: psi verify|ver [options]"));
}
