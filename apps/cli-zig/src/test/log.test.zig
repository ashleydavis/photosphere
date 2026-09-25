const std = @import("std");
const cli = @import("cli-zig");
const utils = @import("utils-zig");
const node_utils = @import("node-utils-zig");
const helpers = @import("test-helpers.zig");
const Log = cli.log.Log;

//
// Captured console output.
//
const Capture = struct {
    // What was written to stdout.
    stdout: std.Io.Writer.Allocating,

    // What was written to stderr.
    stderr: std.Io.Writer.Allocating,
};

test "Log writes each kind of message to the right stream" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var capture = Capture{ .stdout = .init(allocator), .stderr = .init(allocator) };
    utils.console.setCapture(&capture.stdout.writer, &capture.stderr.writer);
    defer utils.console.setCapture(null, null);

    var quiet = Log.init(.{});
    quiet.info("info");
    quiet.verbose("verbose");
    quiet.debug("debug");
    quiet.tool("magick", .{ .stdout = "out", .stderr = null });
    quiet.event("happened");
    quiet.warn("warning");
    quiet.@"error"("failure");
    try std.testing.expect(!quiet.verboseEnabled());
    try std.testing.expectEqualStrings("info\n[EVENT] happened\n", capture.stdout.written());
    try std.testing.expectEqualStrings("warning\nfailure\n", capture.stderr.written());

    capture.stdout.clearRetainingCapacity();
    capture.stderr.clearRetainingCapacity();
    var loud = Log.init(.{ .verbose = true, .debug = true, .tools = true });
    loud.verbose("verbose");
    loud.debug("debug");
    loud.tool("magick", .{ .stdout = "out", .stderr = "err" });
    loud.exception("Something failed", utils.errors.throwError("Cause", .{}));
    try std.testing.expect(loud.verboseEnabled());
    try std.testing.expectEqualStrings("verbose\n== magick stdout ==\nout\n== magick stderr ==\nerr\n", capture.stdout.written());
    try std.testing.expectEqualStrings("debug\nSomething failed\nError: Cause\n", capture.stderr.written());
    const details = try loud.ilog().getLogDetails(allocator, std.testing.io);
    try std.testing.expect(details.logFilePath == null);
}

test "configureLog installs the file logger unless file logging is disabled" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const tmpDir = try helpers.makeTempDir(allocator, "configure-log");
    defer std.Io.Dir.cwd().deleteTree(io, tmpDir) catch {};
    var environ_map = std.process.Environ.Map.init(allocator);
    // os.tmpdir() reads TMPDIR on POSIX and TEMP on Windows.
    try environ_map.put("TMPDIR", tmpDir);
    try environ_map.put("TEMP", tmpDir);
    node_utils.process_env.setEnvironMap(&environ_map);
    defer node_utils.process_env.setEnvironMap(null);
    const previous = utils.log.log;
    defer utils.log.setLog(previous);
    defer node_utils.termination.clearTerminationCallbacks();

    var capture = Capture{ .stdout = .init(allocator), .stderr = .init(allocator) };
    utils.console.setCapture(&capture.stdout.writer, &capture.stderr.writer);
    defer utils.console.setCapture(null, null);

    cli.process_argv.setArgv(&.{"psi"});
    try cli.log.configureLog(allocator, io, .{ .disableFileLogging = true });
    const details = try utils.log.log.getLogDetails(allocator, io);
    try std.testing.expect(details.logFilePath == null);

    try cli.log.configureLog(allocator, io, .{ .verbose = true });
    const fileLogger = cli.log.getFileLogger().?;
    utils.log.log.info("to both");
    try std.testing.expect(utils.log.log.verboseEnabled());
    fileLogger.close();
    const content = try std.Io.Dir.cwd().readFileAlloc(io, fileLogger.getLogFilePath(), allocator, .unlimited);
    try std.testing.expect(std.mem.indexOf(u8, content, "\nCommand: unknown\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "] [INFO] to both\n") != null);
    // (With verbose logging the tool checks of the header also print verbose messages, as in TypeScript.)
    try std.testing.expect(std.mem.endsWith(u8, capture.stdout.written(), "to both\n"));
}

test "writeOutputLine writes a line to stdout and writeErrorLine a line to stderr" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var capture = Capture{ .stdout = .init(allocator), .stderr = .init(allocator) };
    utils.console.setCapture(&capture.stdout.writer, &capture.stderr.writer);
    defer utils.console.setCapture(null, null);

    cli.console_output.writeOutputLine("to stdout");
    cli.console_output.writeErrorLine("to stderr");

    try std.testing.expectEqualStrings("to stdout\n", capture.stdout.written());
    try std.testing.expectEqualStrings("to stderr\n", capture.stderr.written());
}
