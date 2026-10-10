const std = @import("std");
const utils = @import("utils-zig");
const support = @import("test-support.zig");
const main_state = @import("../lib/main-state.zig");
const file_logger = @import("../lib/file-logger.zig");

const TestApp = support.TestApp;

//
// Reads the log file the core started, which is the one file in the logs folder that is not the error log, or null when there is none
// yet. The writer thread of the logger appends in the background, so a caller that needs a line waits for it with waitForLogLine.
//
fn readLogFile(allocator: std.mem.Allocator, app: *TestApp) !?[]u8 {
    const logs_dir = try std.fs.path.join(allocator, &.{ app.tmp_path, "logs-root", "logs" });
    defer allocator.free(logs_dir);
    var directory = std.Io.Dir.cwd().openDir(std.testing.io, logs_dir, .{
        .iterate = true,
    }) catch {
        return null;
    };
    defer directory.close(std.testing.io);
    var iterator = directory.iterate();
    while (try iterator.next(std.testing.io)) |entry| {
        if (std.mem.endsWith(u8, entry.name, "-errors.log")) {
            continue;
        }
        const path = try std.fs.path.join(allocator, &.{ logs_dir, entry.name });
        defer allocator.free(path);
        return try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(1024 * 1024));
    }
    return null;
}

//
// Waits for the log file to hold a line, and returns the whole file. Fails when it never does.
//
fn waitForLogLine(allocator: std.mem.Allocator, app: *TestApp, line: []const u8) ![]u8 {
    var waited_ms: u32 = 0;
    while (waited_ms < 20_000) : (waited_ms += 5) {
        if (try readLogFile(allocator, app)) |text| {
            if (std.mem.indexOf(u8, text, line) != null) {
                return text;
            }
            allocator.free(text);
        }
        try std.testing.io.sleep(.fromMilliseconds(5), .awake);
    }
    return error.LogLineNeverWritten;
}

test "the core starts a log file in the logs folder of PHOTOSPHERE_LOG_DIR, and says that the app is starting" {
    var app: TestApp = undefined;
    try app.start();
    defer app.stop();

    const text = try waitForLogLine(std.testing.allocator, &app, "Photosphere Desktop starting...");
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "Photosphere Desktop Log") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "[Main] Photosphere Desktop starting...") != null);
}

test "the core logs that the instance started, with its process id" {
    var app: TestApp = undefined;
    try app.start();
    defer app.stop();

    const text = try waitForLogLine(std.testing.allocator, &app, "Instance started (pid=");
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "packaged=") != null);
}

test "what the process logs reaches the log file, and the console" {
    var app: TestApp = undefined;
    try app.start();
    defer app.stop();

    utils.log.log.info("a line written by the code under test");

    const text = try waitForLogLine(std.testing.allocator, &app, "a line written by the code under test");
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, app.console_out.written(), "a line written by the code under test") != null);
}

test "the log is the file logger while the core runs" {
    var app: TestApp = undefined;
    try app.start();
    defer app.stop();

    try std.testing.expect(file_logger.FileLogger.fromILog(utils.log.log) != null);
}

test "destroying the core logs that the app is shutting down and ends the log file, and puts the earlier log back" {
    var app: TestApp = undefined;
    const earlier_log = utils.log.log;
    try app.start();
    defer app.stop();
    const text_before = try waitForLogLine(std.testing.allocator, &app, "Instance started (pid=");
    std.testing.allocator.free(text_before);

    app.stopCore();

    try std.testing.expect(utils.log.log.ptr == earlier_log.ptr);
    try std.testing.expect(utils.log.log.vtable == earlier_log.vtable);
    const text = (try readLogFile(std.testing.allocator, &app)).?;
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "[Main] Photosphere Desktop shutting down...") != null);
    // The footer is the last thing written, after the shutting down line, because the logger is closed last.
    const shutting_down = std.mem.indexOf(u8, text, "Photosphere Desktop shutting down...").?;
    try std.testing.expect(std.mem.indexOf(u8, text[shutting_down..], "--- Log End ---") != null);
}
