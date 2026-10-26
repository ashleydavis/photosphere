const std = @import("std");
const ziggy = @import("ziggy");
const utils = @import("utils-zig");
const main_state = @import("photosphere-core").main_state;
const support = @import("test-support.zig");

const TestApp = support.TestApp;
const FileLogger = utils.file_log.FileLog;

//
// The file logger a test installs as the main thread's log, and the log it replaced, which the main thread keeps as its own: made,
// installed, taken out and freed there (see InstalledLogger), with the main thread's Io and the state's allocator.
//
threadlocal var main_thread_logger: ?*FileLogger = null;
threadlocal var main_thread_previous_log: ?utils.log.ILog = null;

//
// The paths of the files of the logger the main thread made, which it sends the test.
//
const ILoggerPaths = struct {
    // The log file.
    logFilePath: []const u8,
    // The error log file.
    errorLogFilePath: []const u8,
};

//
// A file logger installed as the app's log for the length of a test, in a directory the test app owns. The app logs on the core's
// main thread, so the logger is made there and installed as that thread's log, and taken out, closed and freed there again: the test
// keeps only the paths of its files, which it reads once the logger has been closed.
//
const InstalledLogger = struct {
    // Whether the logger is still the main thread's log.
    installed: bool,
    // Whether the logger logged an error, as it reported when it was closed.
    logged_errors: bool,
    // The path of the log file. Owned.
    log_file_path: []u8,
    // The path of the error log file. Owned.
    error_log_file_path: []u8,
    // The test app.
    app: *TestApp,

    //
    // Has the main thread make a logger in a folder of the test app's directory and install it.
    //
    fn start(self: *InstalledLogger, app: *TestApp) !void {
        const allocator = std.testing.allocator;
        self.app = app;
        self.logged_errors = false;
        const logs_dir = try std.fs.path.join(allocator, &.{ app.tmp_path, "logs" });
        defer allocator.free(logs_dir);
        var arena_state = std.heap.ArenaAllocator.init(allocator);
        defer arena_state.deinit();
        const paths = try app.onMainThreadWith(arena_state.allocator(), logs_dir, install);
        self.log_file_path = try allocator.dupe(u8, paths.logFilePath);
        errdefer allocator.free(self.log_file_path);
        self.error_log_file_path = try allocator.dupe(u8, paths.errorLogFilePath);
        self.installed = true;
    }

    //
    // Makes the logger and installs it as the main thread's log, and gives the paths of its files. Runs on the main thread, where the
    // state's tools are: ImageMagick keeps one set of state for the whole program, so the logger runs the tools the app already holds.
    //
    fn install(logs_dir: []const u8, _: ziggy.core.HandlerServices, _: ziggy.timers.Timers, main_io: std.Io, _: std.mem.Allocator) anyerror!ILoggerPaths {
        main_thread_previous_log = utils.log.currentLog();
        const logger = try FileLogger.start(main_state.stateAllocator(), main_io, .{
            .file_prefix = "photosphere",
            .title = "Photosphere Desktop Log",
            .logs_dir = logs_dir,
            .command = null,
            .version = "1.2.3",
            .header_lines = &.{},
            .verbose = false,
            .debug = false,
            .tools = false,
        });
        main_thread_logger = logger;
        return .{
            .logFilePath = logger.getLogFilePath(),
            .errorLogFilePath = logger.getErrorLogFilePath(),
        };
    }

    //
    // Puts the main thread's log back, closes the logger, frees it and returns whether it logged an error. Runs on the main thread.
    //
    fn close(_: u8, _: ziggy.core.HandlerServices, _: ziggy.timers.Timers, main_io: std.Io, _: std.mem.Allocator) anyerror!bool {
        const logger = main_thread_logger.?;
        main_thread_logger = null;
        utils.log.setLog(main_thread_previous_log);
        main_thread_previous_log = null;
        defer logger.stop(main_state.stateAllocator(), main_io);
        try logger.close(main_io);
        return logger.hasLoggedErrors();
    }

    //
    // Has the main thread take the logger out and close it, when it has not already.
    //
    fn uninstall(self: *InstalledLogger) !void {
        if (self.installed) {
            self.installed = false;
            self.logged_errors = try self.app.onMainThread(@as(u8, 0), close);
        }
    }

    //
    // Takes the logger out, closes it and frees everything.
    //
    fn stop(self: *InstalledLogger) void {
        self.uninstall() catch |err| {
            std.debug.print("closing the logger failed: {s}\n", .{@errorName(err)});
        };
        std.testing.allocator.free(self.log_file_path);
        std.testing.allocator.free(self.error_log_file_path);
    }
};

test "get-log-details replies with the path of the log file and its header" {
    var app: TestApp = undefined;
    try app.start();
    defer app.stop();
    var installed: InstalledLogger = undefined;
    try installed.start(&app);
    defer installed.stop();
    const allocator = std.testing.allocator;
    try app.onState(@as(u8, 0), struct {
        fn check(_: u8, _: *main_state.MainState, _: ziggy.core.HandlerServices, _: ziggy.timers.Timers, _: std.Io) anyerror!void {
            utils.log.log.info("logged after the header");
        }
    }.check);
    const reply = try app.requestOk("get-log-details", "null");
    defer allocator.free(reply);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, reply, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings(installed.log_file_path, parsed.value.object.get("logFilePath").?.string);
    const header = parsed.value.object.get("logHeader").?.string;
    try std.testing.expect(std.mem.startsWith(u8, header, "=" ** 80 ++ "\nPhotosphere Desktop Log\n"));
    try std.testing.expect(std.mem.indexOf(u8, header, "\nVersion: 1.2.3\n") != null);
    try std.testing.expect(std.mem.endsWith(u8, header, "\n--- Log Start ---"));
    try std.testing.expect(std.mem.indexOf(u8, header, "logged after the header") == null);
}

test "get-log-details with the console log replies with a null path and the placeholder header" {
    var app: TestApp = undefined;
    try app.start();
    defer app.stop();
    // The core installs its file logger as the main thread's log when it starts, so the main thread is given the console log to
    // test the app with no file logger.
    try app.onState(@as(u8, 0), struct {
        fn check(_: u8, _: *main_state.MainState, _: ziggy.core.HandlerServices, _: ziggy.timers.Timers, _: std.Io) anyerror!void {
            utils.log.setLog(null);
        }
    }.check);
    const reply = try app.requestOk("get-log-details", "null");
    defer std.testing.allocator.free(reply);
    try std.testing.expectEqualStrings("{\"logFilePath\":null,\"logHeader\":\"No log file available\"}", reply);
}

test "get-log-details is an error reply when the log file cannot be read" {
    var app: TestApp = undefined;
    try app.start();
    defer app.stop();
    var installed: InstalledLogger = undefined;
    try installed.start(&app);
    defer installed.stop();
    try std.Io.Dir.cwd().deleteFile(std.testing.io, installed.log_file_path);
    const reply = try app.requestError("get-log-details", "null");
    defer std.testing.allocator.free(reply);
    try std.testing.expectEqualStrings("A file or folder the request needs was not found.", reply);
}

//
// Reads the file of frame rates in the app's data directory. The caller frees it.
//
fn readFpsFile(app: *TestApp) ![]u8 {
    const fps_path = try std.fs.path.join(std.testing.allocator, &.{ app.tmp_path, "photosphere-fps.csv" });
    defer std.testing.allocator.free(fps_path);
    return std.Io.Dir.cwd().readFileAlloc(std.testing.io, fps_path, std.testing.allocator, .limited(1024 * 1024));
}

test "fps-measurement appends a row of the time and the frame rate, with the column header first" {
    var app: TestApp = undefined;
    try app.prepare();
    try app.environ_map.put("FPS_LOGGING", "1");
    try app.launch();
    defer app.stop();
    const allocator = std.testing.allocator;
    const reply = try app.requestOk("fps-measurement", "60");
    defer allocator.free(reply);
    try std.testing.expectEqualStrings("null", reply);
    allocator.free(try app.requestOk("fps-measurement", "59.5"));
    const text = try readFpsFile(&app);
    defer allocator.free(text);
    try std.testing.expect(std.mem.startsWith(u8, text, "timestamp,fps\n"));
    var lines = std.mem.splitScalar(u8, text["timestamp,fps\n".len..], '\n');
    const first = lines.next().?;
    const second = lines.next().?;
    try std.testing.expectEqualStrings("", lines.next().?);
    try std.testing.expect(lines.next() == null);
    try std.testing.expect(std.mem.endsWith(u8, first, ",60"));
    try std.testing.expect(std.mem.endsWith(u8, second, ",59.5"));
    const first_time = try std.fmt.parseInt(i64, first[0 .. first.len - ",60".len], 10);
    const second_time = try std.fmt.parseInt(i64, second[0 .. second.len - ",59.5".len], 10);
    try std.testing.expect(first_time > 1_700_000_000_000);
    try std.testing.expect(second_time >= first_time);
}

test "fps-measurement is an error reply unless FPS_LOGGING is 1" {
    const allocator = std.testing.allocator;
    const off_text = "FPS logging is off. Start Photosphere with the environment variable FPS_LOGGING set to 1 to record frame rates.";
    {
        var app: TestApp = undefined;
        try app.start();
        defer app.stop();
        const off = try app.requestError("fps-measurement", "60");
        defer allocator.free(off);
        try std.testing.expectEqualStrings(off_text, off);
        try std.testing.expectError(error.FileNotFound, readFpsFile(&app));
    }
    var app: TestApp = undefined;
    try app.prepare();
    try app.environ_map.put("FPS_LOGGING", "0");
    try app.launch();
    defer app.stop();
    const zero = try app.requestError("fps-measurement", "60");
    defer allocator.free(zero);
    try std.testing.expectEqualStrings(off_text, zero);
    try std.testing.expectError(error.FileNotFound, readFpsFile(&app));
}

test "fps-measurement with something that is not a number is an error reply" {
    var app: TestApp = undefined;
    try app.prepare();
    try app.environ_map.put("FPS_LOGGING", "1");
    try app.launch();
    defer app.stop();
    const reply = try app.requestError("fps-measurement", "\"fast\"");
    defer std.testing.allocator.free(reply);
    try std.testing.expectEqualStrings("InvalidMessageData: InvalidCharacter", reply);
    try std.testing.expectError(error.FileNotFound, readFpsFile(&app));
}

test "fps-measurement is an error reply that names the file when it cannot be written" {
    var app: TestApp = undefined;
    try app.prepare();
    try app.environ_map.put("FPS_LOGGING", "1");
    try app.launch();
    defer app.stop();
    // A directory where the file should go.
    const fps_path = try std.fs.path.join(std.testing.allocator, &.{ app.tmp_path, "photosphere-fps.csv" });
    defer std.testing.allocator.free(fps_path);
    try std.Io.Dir.cwd().createDir(std.testing.io, fps_path, .default_dir);
    const reply = try app.requestError("fps-measurement", "60");
    defer std.testing.allocator.free(reply);
    try std.testing.expect(std.mem.indexOf(u8, reply, "photosphere-fps.csv") != null);
}
