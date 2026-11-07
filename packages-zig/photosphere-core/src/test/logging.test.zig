const std = @import("std");
const ziggy = @import("ziggy");
const utils = @import("utils-zig");
const main_state = @import("photosphere-core").main_state;
const logging = @import("photosphere-core").logging;
const support = @import("test-support.zig");

const TestApp = support.TestApp;

//
// Gives the path of the log file of the main thread's log, the file log Ziggy started for the app. Runs on the main thread.
//
fn logFilePath(_: u8, services: ziggy.core.HandlerServices, _: ziggy.timers.Timers, _: std.Io, _: std.mem.Allocator) anyerror![]const u8 {
    return services.log.logFilePath() orelse error.NoFileLog;
}

test "get-log-details replies with the path of the log file and its header" {
    var app: TestApp = undefined;
    try app.start();
    defer app.stop();
    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const log_file_path = try app.onMainThreadWith(arena_state.allocator(), @as(u8, 0), logFilePath);
    try app.onState(@as(u8, 0), struct {
        fn check(_: u8, _: *main_state.MainState, services: ziggy.core.HandlerServices, _: ziggy.timers.Timers, _: std.Io) anyerror!void {
            services.log.info("logged after the header");
        }
    }.check);
    const reply = try app.requestOk("get-log-details", "null");
    defer allocator.free(reply);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, reply, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings(log_file_path, parsed.value.object.get("logFilePath").?.string);
    const header = parsed.value.object.get("logHeader").?.string;
    try std.testing.expect(std.mem.startsWith(u8, header, "=" ** 80 ++ "\nPhotosphere\n"));
    try std.testing.expect(std.mem.indexOf(u8, header, "\nVersion: ") != null);
    try std.testing.expect(std.mem.endsWith(u8, header, "\n--- Log Start ---"));
    try std.testing.expect(std.mem.indexOf(u8, header, "logged after the header") == null);
}

test "get-log-details with the console log replies with a null path and the placeholder header" {
    var app: TestApp = undefined;
    try app.start();
    defer app.stop();
    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    // The handler is given the app's services with a mute log, which has no file, in place of the file log Ziggy started, and gives the
    // data of the task it queues.
    const data = try app.onMainThreadWith(arena_state.allocator(), @as(u8, 0), struct {
        fn run(_: u8, services: ziggy.core.HandlerServices, timers: ziggy.timers.Timers, io: std.Io, run_allocator: std.mem.Allocator) anyerror![]const u8 {
            var console_services = services;
            console_services.log = utils.mute_log.MuteLog.init();
            const response = try logging.getLogDetailsMessageHandler(console_services, timers, io, run_allocator, .{});
            try std.testing.expectEqualStrings("get-log-details", response.task.task_type);
            return response.task.data;
        }
    }.run);
    // The JSON writer leaves out a null field, so the task is given no path.
    try std.testing.expectEqualStrings("{}", data);
    try app.queueTaskExpecting("get-log-details", data, "\"outputs\":{\"logFilePath\":null,\"logHeader\":\"No log file available\"}");
}

test "get-log-details is an error reply when the log file cannot be read" {
    var app: TestApp = undefined;
    try app.start();
    defer app.stop();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const log_file_path = try app.onMainThreadWith(arena_state.allocator(), @as(u8, 0), logFilePath);
    try std.Io.Dir.cwd().deleteFile(std.testing.io, log_file_path);
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
