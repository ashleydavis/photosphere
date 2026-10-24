//
// What the tests of Photosphere's handlers share: a core running Photosphere's app, as app.zig registers it, on a fake native
// app, with the settings, the data and the vault pointed at directories that belong to the test.
//

const std = @import("std");
const ziggy = @import("ziggy");
const node_utils = @import("node-utils-zig");
const utils = @import("utils-zig");
const photosphere_app = @import("photosphere-app");
const main_state = @import("photosphere-core").main_state;
const main_process = @import("photosphere-core").main_process;

const process_env = node_utils.process_env;

//
// One message of an app's declaration and its handler.
//
const MessageEntry = @typeInfo(@FieldType(ziggy.core.RegisteredApp, "messages")).pointer.child;

//
// A function a test runs on the core's main thread, which owns the app's state (see TestApp.onMainThread): given the standard
// arguments of a message handler and the JSON of its context, it gives the JSON of its result. Nothing passes between the test's
// thread and the main thread but the JSON text of the message and of its reply: the function is named by its address, which is code
// and the same on every thread.
//
const MainThreadFunction = *const fn (services: ziggy.core.HandlerServices, timers: ziggy.timers.Timers, io: std.Io, allocator: std.mem.Allocator, context: std.json.Value) anyerror!std.json.Value;

//
// The handler of the message that runs a test's function on the main thread. Only the tests' copy of the app has it: the app
// itself never does. The reply holds the function's result, or the number of the error it failed with.
//
fn runOnMainThread(services: ziggy.core.HandlerServices, timers: ziggy.timers.Timers, io: std.Io, allocator: std.mem.Allocator, payload: struct { function: usize, context: std.json.Value }) !ziggy.core.Response(std.json.Value) {
    const function: MainThreadFunction = @ptrFromInt(payload.function);
    var reply: std.json.ObjectMap = .empty;
    if (function(services, timers, io, allocator, payload.context)) |result| {
        try reply.put(allocator, "result", result);
    }
    else |err| {
        try reply.put(allocator, "failure", .{
            .integer = @intFromError(err),
        });
    }
    return .{
        .now = .{
            .object = reply,
        },
    };
}

//
// The result type of a function a test runs on the main thread.
//
fn ResultOf(comptime function: anytype) type {
    return @typeInfo(@typeInfo(@TypeOf(function)).@"fn".return_type.?).error_union.payload;
}

//
// The main thread's side of a function a test runs there: reads the context from its JSON, calls the function and gives its result as
// JSON.
//
fn MainThreadCall(comptime Context: type, comptime function: anytype) type {
    return struct {
        fn run(services: ziggy.core.HandlerServices, timers: ziggy.timers.Timers, io: std.Io, allocator: std.mem.Allocator, context: std.json.Value) anyerror!std.json.Value {
            const given = try std.json.parseFromValueLeaky(Context, allocator, context, .{
                .allocate = .alloc_always,
            });
            const result = try function(given, services, timers, io, allocator);
            if (@TypeOf(result) == void) {
                return .null;
            }
            return try std.json.parseFromSliceLeaky(std.json.Value, allocator, try std.json.Stringify.valueAlloc(allocator, result, .{}), .{});
        }
    };
}

//
// The error number of a function that failed on the main thread, as the reply carries it.
//
const ErrorNumber = std.meta.Int(.unsigned, @bitSizeOf(anyerror));

//
// What the core's main thread wrote to standard output and standard error through the console. The capture of the console is the
// calling thread's, so the main thread makes these as its own, with an allocator of its own, and only it writes and reads them: the
// test reads them by a message to the main thread (see TestApp.consoleOut).
//
threadlocal var main_console_allocator: ziggy.thread_allocator.ThreadAllocator = .init;
threadlocal var main_console_out: std.Io.Writer.Allocating = undefined;
threadlocal var main_console_err: std.Io.Writer.Allocating = undefined;

//
// The type of the app event the main thread sends, as the core stops, with what it wrote through the console, so a test can read it once
// the core has gone (see TestApp.consoleOut).
//
const FINAL_CONSOLE_TYPE = "test-final-console";

//
// Which of the console's streams: standard output or standard error.
//
const ConsoleStream = enum { out, err };

//
// The tests' on_create: gives the main thread its capture of its console before Photosphere's on_create logs anything, then calls it.
// Runs on the main thread.
//
fn createWithCapture(services: ziggy.core.HandlerServices, timers: ziggy.timers.Timers, io: std.Io, allocator: std.mem.Allocator) anyerror!void {
    main_console_out = std.Io.Writer.Allocating.init(main_console_allocator.allocator());
    main_console_err = std.Io.Writer.Allocating.init(main_console_allocator.allocator());
    utils.console.setCapture(&main_console_out.writer, &main_console_err.writer);
    try photosphere_app.app.on_create.?(services, timers, io, allocator);
}

//
// The tests' on_destroy: calls Photosphere's, and once the workers have stopped sends the page what the main thread wrote through the
// console, as an app event the fake native app records, and frees the capture. Runs on the main thread.
//
fn destroyWithCapture(services: ziggy.core.HandlerServices, timers: ziggy.timers.Timers, io: std.Io, allocator: std.mem.Allocator, phase: ziggy.core.DestroyPhase) void {
    photosphere_app.app.on_destroy.?(services, timers, io, allocator, phase);
    if (phase != .after_tasks_stopped) {
        return;
    }
    const event = utils.json.stringify(allocator, .{
        .type = FINAL_CONSOLE_TYPE,
        .out = main_console_out.written(),
        .err = main_console_err.written(),
    }) catch @panic("out of memory sending the main thread's console");
    services.sendEvent(io, allocator, event) catch @panic("out of memory sending the main thread's console");
    utils.console.setCapture(null, null);
    main_console_out.deinit();
    main_console_err.deinit();
    main_console_allocator.deinit();
    main_console_allocator = .init;
}

//
// The main thread's side of reading its console: what it wrote to standard output, or to standard error.
//
fn MainConsole(comptime which: ConsoleStream) type {
    return struct {
        fn read(_: u8, _: ziggy.core.HandlerServices, _: ziggy.timers.Timers, _: std.Io, _: std.mem.Allocator) anyerror![]const u8 {
            return switch (which) {
                .out => main_console_out.written(),
                .err => main_console_err.written(),
            };
        }
    };
}

//
// The message the tests add to the app, made by App as the app's own are.
//
const main_thread_messages = ziggy.core.App(.{
    .messages = .{
        .@"test-on-main-thread" = runOnMainThread,
    },
    .tasks = .{},
    .menu = &[_]ziggy.menu.Menu{},
    .ui_files = &[_]ziggy.UiFile{},
}).messages;

//
// A core running Photosphere's handlers on a fake native app. Declare it, then call start on it in place (the core keeps a pointer
// to the fake native app and the environment, so it must not move), and call stop when the test is done.
//
pub const TestApp = struct {
    // Records every message the core delivers.
    native_app: ziggy.fake_native_app.FakeNativeApp,
    // The environment the code under test reads, with the settings directory and the vault pointed at this test's.
    environ_map: std.process.Environ.Map,
    // The directory the test owns: the settings directory is a folder in it.
    tmp: std.testing.TmpDir,
    // The absolute path of the directory the test owns.
    tmp_path: []u8,
    // What the code under test wrote to standard output through the console (the log's lines among them), kept in memory. The
    // test program's own standard output is how the build system talks to it, so nothing under test may write there.
    console_out: std.Io.Writer.Allocating,
    // What the code under test wrote to standard error through the console, kept in memory.
    console_err: std.Io.Writer.Allocating,
    // What consoleOut and consoleErr last read: what the main thread and the test's thread wrote.
    console_out_copy: std.ArrayList(u8),
    console_err_copy: std.ArrayList(u8),
    // Every task type the core runs: the ones a test added, then Photosphere's.
    tasks: []ziggy.task_runner.TaskHandlerEntry,
    // Every message the core handles: Photosphere's, then the one that runs a test's function on the main thread (see onMainThread).
    messages: []MessageEntry,
    // The id of the next request.
    next_request_id: u32,
    // Whether stopCore has destroyed the core already, so stop does not destroy it again.
    core_stopped: bool,

    //
    // Starts the core. The settings directory (PHOTOSPHERE_CONFIG_DIR) is a new folder that belongs to the test. The vault is the
    // plain-text one, in a directory that is the same for every test of one run of the test program, because the vault code keeps
    // the vault it first opened and every test must find the directory it opened.
    //
    pub fn start(self: *TestApp) !void {
        try self.startWithTasks(&[_]ziggy.task_runner.TaskHandlerEntry{});
    }

    //
    // Starts the core as start does, with task types a test needs added to Photosphere's (a task that runs until it is cancelled,
    // say, which Photosphere has no use for).
    //
    pub fn startWithTasks(self: *TestApp, extra_tasks: []const ziggy.task_runner.TaskHandlerEntry) !void {
        try self.startWithTasksAndConfigFile(extra_tasks, null);
    }

    //
    // Starts the core as startWithTasks does, with config.yaml already on disk holding the text, as it is when the app is started by
    // a user who has set it up. The text is written before the core exists, because the core reads the settings when it starts.
    //
    pub fn startWithTasksAndConfigFile(self: *TestApp, extra_tasks: []const ziggy.task_runner.TaskHandlerEntry, config_yaml: ?[]const u8) !void {
        try self.startWithEverything(extra_tasks, config_yaml, 3, true);
    }

    //
    // Starts the core as start does, with the task runner given this many workers, for a test of what needs a worker.
    //
    pub fn startWithWorkers(self: *TestApp, worker_threads: u32) !void {
        try self.startWithEverything(&[_]ziggy.task_runner.TaskHandlerEntry{}, null, worker_threads, true);
    }

    //
    // Starts the core as start does on a platform whose native app makes no native calls, as every desktop does.
    //
    pub fn startWithoutNativeCall(self: *TestApp) !void {
        try self.startWithEverything(&[_]ziggy.task_runner.TaskHandlerEntry{}, null, 3, false);
    }

    //
    // Does what start does before the core starts: makes the directory the test owns and the environment the core is given, for a
    // test that adds to the environment (environ_map) before it calls launch. The core and its threads take a copy of the
    // environment when they start, as a process is given its environment when it starts, so a change made after launch does not
    // reach them.
    //
    pub fn prepare(self: *TestApp) !void {
        try self.prepareWithConfigFile(null);
    }

    //
    // Starts the core after prepare, as start does.
    //
    pub fn launch(self: *TestApp) !void {
        try self.launchWith(&[_]ziggy.task_runner.TaskHandlerEntry{}, 3, true);
    }

    //
    // Starts the core after prepare, as startWithTasks does.
    //
    pub fn launchWithTasks(self: *TestApp, extra_tasks: []const ziggy.task_runner.TaskHandlerEntry) !void {
        try self.launchWith(extra_tasks, 3, true);
    }

    //
    // Starts the core with the extra task types, config.yaml holding the text when there is one, this many workers, and the native
    // call callback when has_native_call is set.
    //
    fn startWithEverything(self: *TestApp, extra_tasks: []const ziggy.task_runner.TaskHandlerEntry, config_yaml: ?[]const u8, worker_threads: u32, has_native_call: bool) !void {
        try self.prepareWithConfigFile(config_yaml);
        try self.launchWith(extra_tasks, worker_threads, has_native_call);
    }

    //
    // Makes the directory the test owns, with config.yaml holding the text when there is one, the console capture and the
    // environment.
    //
    fn prepareWithConfigFile(self: *TestApp, config_yaml: ?[]const u8) !void {
        const allocator = std.testing.allocator;
        const io = std.testing.io;
        self.native_app.init();
        self.console_out = std.Io.Writer.Allocating.init(allocator);
        self.console_err = std.Io.Writer.Allocating.init(allocator);
        self.console_out_copy = .empty;
        self.console_err_copy = .empty;
        utils.console.setCapture(&self.console_out.writer, &self.console_err.writer);
        self.tmp = std.testing.tmpDir(.{});
        const current_path = try std.process.currentPathAlloc(io, allocator);
        defer allocator.free(current_path);
        self.tmp_path = try std.fs.path.join(allocator, &.{ current_path, ".zig-cache", "tmp", &self.tmp.sub_path });
        const config_dir = try std.fs.path.join(allocator, &.{ self.tmp_path, "config" });
        defer allocator.free(config_dir);
        try std.Io.Dir.cwd().createDirPath(io, config_dir);
        if (config_yaml) |text| {
            const config_path = try std.fs.path.join(allocator, &.{ config_dir, "config.yaml" });
            defer allocator.free(config_path);
            try std.Io.Dir.cwd().writeFile(io, .{
                .sub_path = config_path,
                .data = text,
            });
        }
        const vault_dir = try std.fmt.allocPrint(allocator, "{s}/.zig-cache/tmp/photosphere-core-vault-{x}", .{ current_path, std.testing.random_seed });
        defer allocator.free(vault_dir);
        self.environ_map = std.process.Environ.Map.init(allocator);
        try self.environ_map.put("PHOTOSPHERE_CONFIG_DIR", config_dir);
        // The core runs in test mode, as the smoke tests run the app, so the MCP server takes a free port: tests running side by side
        // would fight over its fixed one.
        try self.environ_map.put("PHOTOSPHERE_TEST_MODE", "1");
        try self.environ_map.put("PHOTOSPHERE_VAULT_TYPE", "plaintext");
        try self.environ_map.put("PHOTOSPHERE_VAULT_DIR", vault_dir);
        // The file logger the core starts writes its files here, in a folder that belongs to the test.
        const log_dir = try std.fs.path.join(allocator, &.{ self.tmp_path, "logs-root" });
        defer allocator.free(log_dir);
        try self.environ_map.put("PHOTOSPHERE_LOG_DIR", log_dir);
        // The cache, which a reset of the app's storage empties, is in the directory the test owns too.
        const cache_dir = try std.fs.path.join(allocator, &.{ self.tmp_path, "cache" });
        defer allocator.free(cache_dir);
        try self.environ_map.put("PHOTOSPHERE_CACHE_DIR", cache_dir);
        process_env.setEnvironMap(&self.environ_map);
    }

    //
    // Starts the core, with the extra task types, this many workers, and native calls when has_native_call is set. Every dialog gives "[]",
    // a user who cancelled, and every native call gives null, until a test sets another result.
    //
    fn launchWith(self: *TestApp, extra_tasks: []const ziggy.task_runner.TaskHandlerEntry, worker_threads: u32, has_native_call: bool) !void {
        const allocator = std.testing.allocator;
        var config = self.native_app.config(worker_threads, 2);
        config.has_native_call = has_native_call;
        const data_dir = try allocator.dupeZ(u8, self.tmp_path);
        defer allocator.free(data_dir);
        config.data_dir = data_dir.ptr;
        self.tasks = try allocator.alloc(ziggy.task_runner.TaskHandlerEntry, photosphere_app.app.tasks.len + extra_tasks.len);
        // A worker runs the first task type of a name, so the ones a test adds come first and stand in for Photosphere's of the same
        // name.
        @memcpy(self.tasks[0..extra_tasks.len], extra_tasks);
        @memcpy(self.tasks[extra_tasks.len..], photosphere_app.app.tasks);
        self.messages = try allocator.alloc(MessageEntry, photosphere_app.app.messages.len + main_thread_messages.len);
        @memcpy(self.messages[0..photosphere_app.app.messages.len], photosphere_app.app.messages);
        @memcpy(self.messages[photosphere_app.app.messages.len..], main_thread_messages);
        var app = photosphere_app.app;
        app.tasks = self.tasks;
        app.messages = self.messages;
        // The main thread captures its own console from on_create on, so it writes nothing to the real standard output, which is how
        // the build system talks to the test program.
        app.on_create = createWithCapture;
        app.on_destroy = destroyWithCapture;
        try self.native_app.start(std.testing.io, std.testing.allocator, config, app);
        self.native_app.setResult(std.testing.io, std.testing.allocator, "pick-paths", true, "[]");
        self.native_app.setResult(std.testing.io, std.testing.allocator, "native-call", true, "null");
        self.next_request_id = 1;
        self.core_stopped = false;
    }

    //
    // What the code under test wrote to standard output through the console, on the core's main thread and then on the test's thread.
    // The text stays valid until the next call.
    //
    pub fn consoleOut(self: *TestApp) ![]const u8 {
        return self.readConsole(.out, &self.console_out, &self.console_out_copy);
    }

    //
    // Has every dialog from now on give the paths, the JSON text of an array of paths. "[]" is a user who cancelled.
    //
    pub fn setPickResult(self: *TestApp, paths: []const u8) void {
        self.native_app.setResult(std.testing.io, std.testing.allocator, "pick-paths", true, paths);
    }

    //
    // A dialog the native app was told to show: its kind (0 open files, 1 save, 2 folder), its title and its initial name or folder.
    //
    pub const Pick = struct {
        kind: i32,
        title: ?[]const u8 = null,
        initialName: ?[]const u8 = null,
    };

    //
    // The last dialog the native app was told to show, with its strings allocated with the arena, or null when none has been.
    //
    pub fn lastPick(self: *TestApp, arena: std.mem.Allocator) !?Pick {
        const text = (try self.native_app.lastCall(std.testing.io, arena, "pick-paths")) orelse {
            return null;
        };
        return try std.json.parseFromSliceLeaky(Pick, arena, text, .{
            .ignore_unknown_fields = true,
        });
    }

    //
    // The kind of the last dialog the native app was told to show (0 open files, 1 save, 2 folder), read with the arena, or -1 when
    // none has been.
    //
    pub fn lastPickKind(self: *TestApp, arena: std.mem.Allocator) !i32 {
        const pick = (try self.lastPick(arena)) orelse {
            return -1;
        };
        return pick.kind;
    }

    //
    // Has every native call from now on give the text: as its result, JSON text, when `succeeded`, and as the reason it failed otherwise.
    //
    pub fn setNativeCallResult(self: *TestApp, succeeded: bool, text: []const u8) void {
        self.native_app.setResult(std.testing.io, std.testing.allocator, "native-call", succeeded, text);
    }

    //
    // A native call the native app was made: the method and the JSON text of its request.
    //
    pub const NativeCall = struct {
        method: []const u8,
        request: []const u8,
    };

    //
    // The last native call the native app was made, with its strings allocated with the arena, or null when none has been.
    //
    pub fn lastNativeCall(self: *TestApp, arena: std.mem.Allocator) !?NativeCall {
        const text = (try self.native_app.lastCall(std.testing.io, arena, "native-call")) orelse {
            return null;
        };
        return try std.json.parseFromSliceLeaky(NativeCall, arena, text, .{
            .ignore_unknown_fields = true,
        });
    }

    //
    // What the code under test wrote to standard error through the console, as consoleOut gives it.
    //
    pub fn consoleErr(self: *TestApp) ![]const u8 {
        return self.readConsole(.err, &self.console_err, &self.console_err_copy);
    }

    //
    // Reads what the main thread wrote, by a message to it while it runs or from the event it sent as it stopped, and then what the test's
    // thread wrote, into the copy.
    //
    fn readConsole(self: *TestApp, comptime which: ConsoleStream, own_capture: *std.Io.Writer.Allocating, copy: *std.ArrayList(u8)) ![]const u8 {
        const allocator = std.testing.allocator;
        const main_text = if (self.core_stopped) try self.finalConsole(which) else switch (which) {
            .out => try self.onMainThreadText(@as(u8, 0), MainConsole(.out).read),
            .err => try self.onMainThreadText(@as(u8, 0), MainConsole(.err).read),
        };
        defer allocator.free(main_text);
        copy.clearRetainingCapacity();
        try copy.appendSlice(allocator, main_text);
        try copy.appendSlice(allocator, own_capture.written());
        return copy.items;
    }

    //
    // What the main thread wrote to standard output or standard error, from the event it sent as the core stopped (see
    // destroyWithCapture). The caller frees it.
    //
    fn finalConsole(self: *TestApp, comptime which: ConsoleStream) ![]u8 {
        const allocator = std.testing.allocator;
        const io = std.testing.io;
        const index = self.native_app.indexOfContaining(io, allocator, "\"type\":\"" ++ FINAL_CONSOLE_TYPE ++ "\"") orelse {
            return error.NoFinalConsole;
        };
        const message = try self.native_app.messageAt(io, allocator, index);
        defer allocator.free(message);
        var arena_state = std.heap.ArenaAllocator.init(allocator);
        defer arena_state.deinit();
        const parsed = try std.json.parseFromSliceLeaky(struct { data: struct { out: []const u8, err: []const u8 } }, arena_state.allocator(), message, .{
            .ignore_unknown_fields = true,
        });
        return try allocator.dupe(u8, switch (which) {
            .out => parsed.data.out,
            .err => parsed.data.err,
        });
    }

    //
    // Destroys the core and leaves everything the test owns in place, for a test that reads what the core left behind when it was destroyed
    // (the log files, say). stop then removes the rest.
    //
    pub fn stopCore(self: *TestApp) void {
        self.native_app.stop(std.testing.io, std.testing.allocator);
        self.core_stopped = true;
    }

    //
    // Stops the core and removes everything the test owns.
    //
    pub fn stop(self: *TestApp) void {
        if (!self.core_stopped) {
            self.native_app.stop(std.testing.io, std.testing.allocator);
        }
        process_env.setEnvironMap(null);
        utils.console.setCapture(null, null);
        self.console_out.deinit();
        self.console_err.deinit();
        self.console_out_copy.deinit(std.testing.allocator);
        self.console_err_copy.deinit(std.testing.allocator);
        self.environ_map.deinit();
        std.testing.allocator.free(self.tmp_path);
        std.testing.allocator.free(self.tasks);
        std.testing.allocator.free(self.messages);
        self.tmp.cleanup();
        self.native_app.deinit(std.testing.io, std.testing.allocator);
    }

    //
    // Sends an app message of the name with the data (JSON text), as the page does ({"kind":"app", "id", "name", "data"}), and waits for its
    // reply, which it returns as the JSON text of the whole reply message ({"id":..,"ok":..,"data":..} or {"id":..,"ok":false,"error":..}).
    // The caller frees it.
    //
    pub fn request(self: *TestApp, message_name: []const u8, data_json: []const u8) ![]u8 {
        const allocator = std.testing.allocator;
        const id = self.next_request_id;
        self.next_request_id += 1;
        const message = try utils.json.stringify(allocator, .{
            .kind = "app",
            .id = id,
            .name = message_name,
            .data = utils.json.Raw{ .text = data_json },
        });
        defer allocator.free(message);
        self.native_app.sendMessage(std.testing.allocator, message);
        const reply_start = try std.fmt.allocPrint(allocator, "{{\"id\":{d},\"ok\":", .{id});
        defer allocator.free(reply_start);
        try self.native_app.expectMessageContaining(std.testing.io, std.testing.allocator, reply_start);
        return try self.native_app.messageAt(std.testing.io, allocator, self.native_app.indexOfContaining(std.testing.io, std.testing.allocator, reply_start).?);
    }

    //
    // Runs function(context, services, timers, io, allocator) on the core's main thread, which owns the app's state, and waits for it:
    // what it reads and changes there is read and changed where the app's own code does. The context and the result go as JSON, so
    // each is a value std.json can write and read: the result one that needs no memory to read (a bool or a number, for example). Returns the
    // error the function returned.
    //
    pub fn onMainThread(self: *TestApp, context: anytype, comptime function: anytype) !ResultOf(function) {
        const Result = ResultOf(function);
        const reply = try self.callOnMainThread(context, function);
        defer std.testing.allocator.free(reply);
        var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena_state.deinit();
        const result = try readMainThreadReply(arena_state.allocator(), reply);
        if (Result == void) {
            return;
        }
        return try std.json.parseFromValueLeaky(Result, arena_state.allocator(), result, .{});
    }

    //
    // Runs the function on the core's main thread, as onMainThread does, for a function whose result needs memory to read (holds text,
    // for example): the result is read with the arena.
    //
    pub fn onMainThreadWith(self: *TestApp, arena: std.mem.Allocator, context: anytype, comptime function: anytype) !ResultOf(function) {
        const reply = try self.callOnMainThread(context, function);
        defer std.testing.allocator.free(reply);
        const result = try readMainThreadReply(arena, reply);
        return try std.json.parseFromValueLeaky(ResultOf(function), arena, result, .{
            .allocate = .alloc_always,
        });
    }

    //
    // Runs a function that gives text on the core's main thread, as onMainThread does, and returns the text. The caller frees it.
    //
    pub fn onMainThreadText(self: *TestApp, context: anytype, comptime function: anytype) ![]u8 {
        const reply = try self.callOnMainThread(context, function);
        defer std.testing.allocator.free(reply);
        var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena_state.deinit();
        const result = try readMainThreadReply(arena_state.allocator(), reply);
        if (result != .string) {
            return error.MainThreadGaveNoText;
        }
        return try std.testing.allocator.dupe(u8, result.string);
    }

    //
    // Sends the message that runs the function on the main thread with the context, and returns the JSON text of the reply's data.
    // The caller frees it.
    //
    fn callOnMainThread(self: *TestApp, context: anytype, comptime function: anytype) ![]u8 {
        const allocator = std.testing.allocator;
        const call: MainThreadFunction = &MainThreadCall(@TypeOf(context), function).run;
        // Null fields are written out, because the main thread reads the context back into its type, which may give them no default.
        const data = try std.json.Stringify.valueAlloc(allocator, .{
            .function = @intFromPtr(call),
            .context = context,
        }, .{});
        defer allocator.free(data);
        return try self.requestOk("test-on-main-thread", data);
    }

    //
    // Runs check(context, state, services, timers, io) on the main thread with Photosphere's state there and the main thread's handler
    // services, timers and Io, as onMainThread does: for a test that reads or changes the state. Returns what the check returns.
    //
    pub fn onState(self: *TestApp, context: anytype, comptime check: anytype) !ResultOf(check) {
        const Context = @TypeOf(context);
        const Call = struct {
            fn run(given: Context, services: ziggy.core.HandlerServices, timers: ziggy.timers.Timers, io: std.Io, _: std.mem.Allocator) anyerror!ResultOf(check) {
                return try check(given, main_state.current(), services, timers, io);
            }
        };
        return try self.onMainThread(context, Call.run);
    }

    //
    // Sends a request that is expected to succeed and returns the JSON text of the reply's data. The caller frees it.
    //
    pub fn requestOk(self: *TestApp, message_name: []const u8, data_json: []const u8) ![]u8 {
        const allocator = std.testing.allocator;
        const reply = try self.request(message_name, data_json);
        defer allocator.free(reply);
        const marker = ",\"ok\":true,\"data\":";
        const marker_at = std.mem.indexOf(u8, reply, marker) orelse {
            std.debug.print("the {s} message did not succeed: {s}\n", .{ message_name, reply });
            return error.RequestFailed;
        };
        const data_start = marker_at + marker.len;
        return try allocator.dupe(u8, reply[data_start .. reply.len - 1]);
    }

    //
    // Sends a request that is expected to fail and returns the text of the reply's error. The caller frees it.
    //
    pub fn requestError(self: *TestApp, message_name: []const u8, data_json: []const u8) ![]u8 {
        const allocator = std.testing.allocator;
        const reply = try self.request(message_name, data_json);
        defer allocator.free(reply);
        const marker = ",\"ok\":false,\"error\":";
        const marker_at = std.mem.indexOf(u8, reply, marker) orelse {
            std.debug.print("the {s} message did not fail: {s}\n", .{ message_name, reply });
            return error.RequestSucceeded;
        };
        const error_json = reply[marker_at + marker.len .. reply.len - 1];
        var parsed = try std.json.parseFromSlice([]const u8, allocator, error_json, .{});
        defer parsed.deinit();
        return try allocator.dupe(u8, parsed.value);
    }

    //
    // Queues a task of the type with the data (JSON text), as Ziggy's add-task system message does, and waits for it to end as
    // failed. A test of what a task does with data its message would refuse reaches the task this way.
    //
    pub fn queueFailingTask(self: *TestApp, task_type: []const u8, data_json: []const u8) !void {
        const allocator = std.testing.allocator;
        const task_id = try std.fmt.allocPrint(allocator, "failing-{s}-{d}", .{ task_type, self.next_request_id });
        defer allocator.free(task_id);
        self.next_request_id += 1;
        const message = try utils.json.stringify(allocator, .{
            .kind = "system",
            .name = "add-task",
            .data = .{
                .taskId = task_id,
                .taskType = task_type,
                .source = "test",
                .data = utils.json.Raw{ .text = data_json },
                .priority = "interactive",
            },
        });
        defer allocator.free(message);
        self.native_app.sendMessage(std.testing.allocator, message);
        const failed = try std.fmt.allocPrint(allocator, "\"taskId\":\"{s}\",\"status\":\"failed\"", .{task_id});
        defer allocator.free(failed);
        try self.native_app.expectMessageContaining(std.testing.io, std.testing.allocator, failed);
    }
};

//
// The result of a function run on the main thread, from the JSON text of the reply's data, read with the arena: the error the function
// failed with, or the JSON of its result.
//
fn readMainThreadReply(arena: std.mem.Allocator, reply: []const u8) !std.json.Value {
    const parsed = try std.json.parseFromSliceLeaky(struct { result: ?std.json.Value = null, failure: ?ErrorNumber = null }, arena, reply, .{});
    if (parsed.failure) |number| {
        return @errorFromInt(number);
    }
    return parsed.result orelse .null;
}

//
// Tells the main process that a task ended, on the main thread, as Ziggy does.
//
pub fn endTask(app: *TestApp, end: ziggy.types.TaskEnd) !void {
    try app.onMainThread(end, struct {
        fn run(given: ziggy.types.TaskEnd, services: ziggy.core.HandlerServices, timers: ziggy.timers.Timers, io: std.Io, allocator: std.mem.Allocator) anyerror!void {
            main_process.onTaskEnd(services, timers, io, allocator, given);
        }
    }.run);
}

//
// Tells the main process that a task sent an event, on the main thread, as Ziggy does.
//
pub fn sendTaskEvent(app: *TestApp, sent: ziggy.types.TaskSentEvent) !void {
    try app.onMainThread(sent, struct {
        fn run(given: ziggy.types.TaskSentEvent, services: ziggy.core.HandlerServices, timers: ziggy.timers.Timers, io: std.Io, allocator: std.mem.Allocator) anyerror!void {
            main_process.onTaskEvent(services, timers, io, allocator, given);
        }
    }.run);
}
