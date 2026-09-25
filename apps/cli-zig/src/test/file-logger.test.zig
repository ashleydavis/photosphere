const std = @import("std");
const builtin = @import("builtin");
const cli = @import("cli-zig");
const utils = @import("utils-zig");
const node_utils = @import("node-utils-zig");
const helpers = @import("test-helpers.zig");
const FileLogger = cli.file_logger.FileLogger;

test "toFixed2 matches toFixed(2)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const fixture = try helpers.loadFixture(allocator, "to-fixed.json");
    for (fixture.array.items) |fixedCase| {
        const milliseconds: f64 = @floatFromInt(helpers.intField(fixedCase, "milliseconds"));
        try std.testing.expectEqualStrings(helpers.stringField(fixedCase, "output"), try cli.file_logger.toFixed2(allocator, milliseconds / 1000));
    }
}

test "the file logger writes the headers, entries and footers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const tmpDir = try helpers.makeTempDir(allocator, "file-logger");
    defer std.Io.Dir.cwd().deleteTree(io, tmpDir) catch {};
    var environ_map = std.process.Environ.Map.init(allocator);
    // os.tmpdir() reads TMPDIR on POSIX and TEMP on Windows.
    try environ_map.put("TMPDIR", tmpDir);
    try environ_map.put("TEMP", tmpDir);
    node_utils.process_env.setEnvironMap(&environ_map);
    defer node_utils.process_env.setEnvironMap(null);
    cli.process_argv.setArgv(&.{ "psi", "verify", "--db", "x" });

    var stdout_capture = std.Io.Writer.Allocating.init(allocator);
    var stderr_capture = std.Io.Writer.Allocating.init(allocator);
    utils.console.setCapture(&stdout_capture.writer, &stderr_capture.writer);
    defer utils.console.setCapture(null, null);

    var consoleLog = cli.log.Log.init(.{});
    const logger = try FileLogger.create(allocator, io, consoleLog.ilog(), "verify --db x");
    defer node_utils.termination.clearTerminationCallbacks();

    const logFile = logger.getLogFilePath();
    try std.testing.expect(std.mem.startsWith(u8, logFile, try std.fs.path.join(allocator, &.{ tmpDir, "photosphere", "logs", "psi-" })));
    try std.testing.expect(std.mem.endsWith(u8, logFile, ".log"));
    try std.testing.expect(std.mem.endsWith(u8, logger.getErrorLogFilePath(), "-errors.log"));
    const baseName = std.fs.path.basename(logFile);
    // psi-YYYY-MM-DDTHH-mm-ss.log
    try std.testing.expectEqual(@as(usize, "psi-".len + 19 + ".log".len), baseName.len);
    try std.testing.expectEqual(@as(u8, 'T'), baseName[14]);

    logger.info("hello info");
    logger.@"error"("bad thing");
    logger.verbose("hidden verbose");
    try std.testing.expect(logger.hasLoggedErrors());
    logger.close();
    logger.info("after close");

    const logContent = try std.Io.Dir.cwd().readFileAlloc(io, logFile, allocator, .unlimited);
    try std.testing.expect(std.mem.startsWith(u8, logContent, "=" ** 80 ++ "\nPhotosphere CLI Log\nStarted: "));
    try std.testing.expect(std.mem.indexOf(u8, logContent, "\nCommand: verify --db x\n") != null);
    const platform = switch (builtin.os.tag) {
        .windows => "win32",
        .macos => "darwin",
        else => "linux",
    };
    try std.testing.expect(std.mem.indexOf(u8, logContent, "\n--- System Information ---\nPlatform: " ++ platform ++ "\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, logContent, "\n--- Photosphere Version ---\ndev\nBuild Commit: dev\nBuild Date: development\nNightly Build: false\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, logContent, "\n--- Tool Versions ---\nImageMagick: ") != null);
    try std.testing.expect(std.mem.indexOf(u8, logContent, "\n--- Command ---\npsi verify --db x\n--- Log Start ---\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, logContent, "] [INFO] hello info\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, logContent, "] [ERROR] bad thing\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, logContent, "] [VERBOSE] hidden verbose\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, logContent, "after close") == null);
    try std.testing.expect(std.mem.indexOf(u8, logContent, "\n--- Log End ---\nCompleted: ") != null);
    try std.testing.expect(std.mem.endsWith(u8, logContent, "s)\n" ++ "=" ** 80 ++ "\n"));

    const errorContent = try std.Io.Dir.cwd().readFileAlloc(io, logger.getErrorLogFilePath(), allocator, .unlimited);
    try std.testing.expect(std.mem.startsWith(u8, errorContent, "=" ** 80 ++ "\nPhotosphere CLI Error Log\n"));
    try std.testing.expect(std.mem.indexOf(u8, errorContent, "If this file contains nothing below, it means there were no errors.\n\n--- Error Log Start ---\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, errorContent, "] [ERROR] bad thing\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, errorContent, "hello info") == null);
    try std.testing.expect(std.mem.indexOf(u8, errorContent, "\n--- Error Log End ---\n") != null);

    try std.testing.expect(std.mem.indexOf(u8, stdout_capture.written(), "hello info\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, stdout_capture.written(), "hidden verbose") == null);
    try std.testing.expect(std.mem.indexOf(u8, stdout_capture.written(), try std.fmt.allocPrint(allocator, "\nErrors, warnings, and exceptions were logged to: {s}\n", .{logger.getErrorLogFilePath()})) != null);
    try std.testing.expectEqualStrings("bad thing\n", stderr_capture.written());

    const details = try logger.getLogDetails(allocator, io);
    try std.testing.expectEqualStrings(logFile, details.logFilePath.?);
    try std.testing.expect(std.mem.endsWith(u8, details.logHeader, "--- Log Start ---"));
}

test "the error log footer is only written when errors were logged" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const tmpDir = try helpers.makeTempDir(allocator, "file-logger-clean");
    defer std.Io.Dir.cwd().deleteTree(io, tmpDir) catch {};
    var environ_map = std.process.Environ.Map.init(allocator);
    // os.tmpdir() reads TMPDIR on POSIX and TEMP on Windows.
    try environ_map.put("TMPDIR", tmpDir);
    try environ_map.put("TEMP", tmpDir);
    node_utils.process_env.setEnvironMap(&environ_map);
    defer node_utils.process_env.setEnvironMap(null);

    var stdout_capture = std.Io.Writer.Allocating.init(allocator);
    utils.console.setCapture(&stdout_capture.writer, &stdout_capture.writer);
    defer utils.console.setCapture(null, null);

    var consoleLog = cli.log.Log.init(.{ .verbose = true });
    const logger = try FileLogger.create(allocator, io, consoleLog.ilog(), "unknown");
    defer node_utils.termination.clearTerminationCallbacks();
    try std.testing.expect(logger.verboseEnabled());
    logger.close();
    const errorContent = try std.Io.Dir.cwd().readFileAlloc(io, logger.getErrorLogFilePath(), allocator, .unlimited);
    try std.testing.expect(std.mem.endsWith(u8, errorContent, "--- Error Log Start ---\n"));
    try std.testing.expect(std.mem.indexOf(u8, stdout_capture.written(), "Errors, warnings") == null);
}

test "the log files go under the process temporary directory when PHOTOSPHERE_TMP_DIR is set" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const tmpDir = try helpers.makeTempDir(allocator, "file-logger-process-tmp");
    defer std.Io.Dir.cwd().deleteTree(io, tmpDir) catch {};
    var environ_map = std.process.Environ.Map.init(allocator);
    try environ_map.put("TMPDIR", try std.fs.path.join(allocator, &.{ tmpDir, "os" }));
    try environ_map.put("TEMP", try std.fs.path.join(allocator, &.{ tmpDir, "os" }));
    try environ_map.put("PHOTOSPHERE_TMP_DIR", tmpDir);
    node_utils.process_env.setEnvironMap(&environ_map);
    defer node_utils.process_env.setEnvironMap(null);
    cli.process_argv.setArgv(&.{ "psi", "verify" });

    var stdout_capture = std.Io.Writer.Allocating.init(allocator);
    utils.console.setCapture(&stdout_capture.writer, &stdout_capture.writer);
    defer utils.console.setCapture(null, null);

    var consoleLog = cli.log.Log.init(.{});
    const logger = try FileLogger.create(allocator, io, consoleLog.ilog(), "verify");
    defer node_utils.termination.clearTerminationCallbacks();
    defer logger.close();

    // getProcessTmpDir is PHOTOSPHERE_TMP_DIR/tmp.
    try std.testing.expect(std.mem.startsWith(u8, logger.getLogFilePath(), try std.fs.path.join(allocator, &.{ tmpDir, "tmp", "photosphere", "logs", "psi-" })));
}
