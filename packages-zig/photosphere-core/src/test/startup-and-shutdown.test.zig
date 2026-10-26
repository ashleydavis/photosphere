const std = @import("std");
const ziggy = @import("ziggy");
const utils = @import("utils-zig");
const support = @import("test-support.zig");
const main_state = @import("photosphere-core").main_state;
const main_process = @import("photosphere-core").main_process;

const TestApp = support.TestApp;
const sendTaskEvent = support.sendTaskEvent;

//
// Reads the log file the core started, which is the one file in the logs folder that is not the error log, or null when there is none
// yet. The core's main thread writes it, so a caller that needs a line it has not seen written waits for it with waitForLogLine.
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

    try std.testing.expect(std.mem.startsWith(u8, text, "=" ** 80 ++ "\nPhotosphere\n"));
    try std.testing.expect(std.mem.indexOf(u8, text, "] [INFO] Photosphere Desktop starting...\n") != null);
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

    // Logged by code running on the main thread, as the app's code runs.
    try app.onState(@as(u8, 0), struct {
        fn check(_: u8, _: *main_state.MainState, _: ziggy.core.HandlerServices, _: ziggy.timers.Timers, _: std.Io) anyerror!void {
            utils.log.log.info("a line written by the code under test");
        }
    }.check);

    const text = try waitForLogLine(std.testing.allocator, &app, "a line written by the code under test");
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, (try app.consoleOut()), "a line written by the code under test") != null);
}

test "the log is the file logger on the main thread while the core runs" {
    var app: TestApp = undefined;
    try app.start();
    defer app.stop();

    try app.onState(@as(u8, 0), struct {
        fn check(_: u8, _: *main_state.MainState, _: ziggy.core.HandlerServices, _: ziggy.timers.Timers, _: std.Io) anyerror!void {
            try std.testing.expect(utils.file_log.FileLog.fromILog(utils.log.currentLog()) != null);
        }
    }.check);
}

test "destroying the core logs that the app is shutting down and ends the log file, and the thread that made the core keeps its own log" {
    var app: TestApp = undefined;
    const earlier_log = utils.log.currentLog();
    try app.start();
    defer app.stop();
    const text_before = try waitForLogLine(std.testing.allocator, &app, "Instance started (pid=");
    std.testing.allocator.free(text_before);
    // The file logger is the main thread's log, so the thread that made the core has the log it had before.
    try std.testing.expect(utils.log.currentLog().ptr == earlier_log.ptr);
    try std.testing.expect(utils.log.currentLog().vtable == earlier_log.vtable);

    app.stopCore();

    try std.testing.expect(utils.log.currentLog().ptr == earlier_log.ptr);
    try std.testing.expect(utils.log.currentLog().vtable == earlier_log.vtable);
    const text = (try readLogFile(std.testing.allocator, &app)).?;
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "] [INFO] Photosphere Desktop shutting down...\n") != null);
    // The footer is the last thing written, after the shutting down line, because the logger is closed last.
    const shutting_down = std.mem.indexOf(u8, text, "Photosphere Desktop shutting down...").?;
    try std.testing.expect(std.mem.indexOf(u8, text[shutting_down..], "--- Log End ---") != null);
}

test "a sync that moved changes is logged as having synced them" {
    var app: TestApp = undefined;
    try app.start();
    defer app.stop();
    try sendTaskEvent(&app, .{
        .task_id = "sync-1",
        .task_type = "sync-database",
        .source = "/db",
        .event_json ="{\"type\":\"sync-completed\",\"databasePath\":\"/db\",\"synced\":true}",
    });

    const text = try waitForLogLine(std.testing.allocator, &app, "Sync completed: changes synced");
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "Sync completed: nothing to sync") == null);
}

test "a sync that found both sides identical is logged as having nothing to sync" {
    var app: TestApp = undefined;
    try app.start();
    defer app.stop();
    try sendTaskEvent(&app, .{
        .task_id = "sync-1",
        .task_type = "sync-database",
        .source = "/db",
        .event_json ="{\"type\":\"sync-completed\",\"databasePath\":\"/db\",\"synced\":false}",
    });

    const text = try waitForLogLine(std.testing.allocator, &app, "Sync completed: nothing to sync");
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "Sync completed: changes synced") == null);
}

test "the log is headed with Photosphere's title and version from its app.zon, and gives the versions of the tools built into the program after its header" {
    var app: TestApp = undefined;
    try app.start();
    defer app.stop();

    const text = try waitForLogLine(std.testing.allocator, &app, "] [INFO] FFprobe: ");
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.startsWith(u8, text, "=" ** 80 ++ "\nPhotosphere\n"));
    const start = std.mem.indexOf(u8, text, "--- Log Start ---") orelse return error.NoLogStart;
    try std.testing.expect(std.mem.indexOf(u8, text[0..start], "\nVersion: ") != null);
    try std.testing.expect(std.mem.indexOf(u8, text[start..], "] [INFO] --- Tool Versions ---\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text[start..], "] [INFO] ImageMagick: ") != null);
    try std.testing.expect(std.mem.indexOf(u8, text[start..], "] [INFO] FFmpeg: ") != null);
    try std.testing.expect(std.mem.indexOf(u8, text[start..], "] [INFO] FFprobe: ") != null);
}
