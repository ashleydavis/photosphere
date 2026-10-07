//
// What the tests of Photosphere's handlers share: a core running Photosphere's channels and task types on a stand-in shell,
// with the settings, the data and the vault pointed at directories that belong to the test.
//

const std = @import("std");
const ziggy = @import("ziggy-core");
const node_utils = @import("node-utils-zig");
const utils = @import("utils-zig");
const handlers = @import("../lib/handlers.zig");

const process_env = node_utils.process_env;

//
// A core running Photosphere's handlers on a stand-in shell. Declare it, then call start on it in place (the core keeps a pointer to
// the stand-in shell and the environment, so it must not move), and call stop when the test is done.
//
pub const TestApp = struct {
    // Records every message the core delivers.
    shell: ziggy.fake_shell.FakeShell,
    // The environment the code under test reads, with the settings directory and the vault pointed at this test's.
    environ_map: std.process.Environ.Map,
    // The directory the test owns: the settings directory is a folder in it.
    tmp: std.testing.TmpDir,
    // The absolute path of the directory the test owns.
    tmp_path: []u8,
    // The core under test.
    core: *ziggy.core.Core,
    // What the code under test wrote to standard output through the console (the log's lines among them), kept in memory. The
    // test program's own standard output is how the build system talks to it, so nothing under test may write there.
    console_out: std.Io.Writer.Allocating,
    // What the code under test wrote to standard error through the console, kept in memory.
    console_err: std.Io.Writer.Allocating,
    // Every task type the core runs: Photosphere's, then the ones a test added.
    tasks: []ziggy.task_runner.TaskHandlerEntry,
    // The answer the next dialog gives, as the JSON text of an array of paths. "[]" is a user who cancelled.
    pick_answer: []const u8,
    // The kind of the last dialog shown (0 open files, 1 save, 2 folder), or -1 when none has been shown.
    last_pick_kind: i32,
    // The title the last dialog was given, or null. Owned.
    last_pick_title: ?[]u8,
    // The initial name or folder the last dialog was given, or null. Owned.
    last_pick_initial: ?[]u8,
    // The answer the next host request gets, as JSON text, or the reason it could not be done when host_fails is set.
    host_answer: []const u8,
    // Whether the next host request fails, with host_answer as its reason.
    host_fails: bool,
    // The method of the last host request, or null when none has been made. Owned.
    last_host_method: ?[]u8,
    // The JSON request of the last host request, or null when none has been made. Owned.
    last_host_request: ?[]u8,
    // The id of the next request.
    next_request_id: u32,

    //
    // Starts the core. The settings directory (PHOTOSPHERE_CONFIG_DIR) is a new folder that belongs to the test. The vault is the
    // plain-text one, in a directory that is the same for every test of one run of the test program, because the vault code keeps
    // the vault it first opened (as the TypeScript does) and every test must find the directory it opened.
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
        const allocator = std.testing.allocator;
        const io = std.testing.io;
        self.shell.init(allocator);
        self.console_out = std.Io.Writer.Allocating.init(allocator);
        self.console_err = std.Io.Writer.Allocating.init(allocator);
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
        try self.environ_map.put("PHOTOSPHERE_VAULT_TYPE", "plaintext");
        try self.environ_map.put("PHOTOSPHERE_VAULT_DIR", vault_dir);
        process_env.setEnvironMap(&self.environ_map);
        var config = self.shell.config(2, 2);
        config.pick_paths = recordingPick;
        config.host_request = recordingHostRequest;
        const data_dir = try allocator.dupeZ(u8, self.tmp_path);
        defer allocator.free(data_dir);
        config.data_dir = data_dir.ptr;
        self.tasks = try allocator.alloc(ziggy.task_runner.TaskHandlerEntry, handlers.tasks.len + extra_tasks.len);
        @memcpy(self.tasks[0..handlers.tasks.len], &handlers.tasks);
        @memcpy(self.tasks[handlers.tasks.len..], extra_tasks);
        var app = handlers.appHandlers("[]", &[_]ziggy.ui_files.UiFile{});
        app.tasks = self.tasks;
        self.core = try ziggy.core.Core.create(allocator, config, app);
        self.next_request_id = 1;
        self.pick_answer = "[]";
        self.last_pick_kind = -1;
        self.last_pick_title = null;
        self.last_pick_initial = null;
        self.host_answer = "null";
        self.host_fails = false;
        self.last_host_method = null;
        self.last_host_request = null;
    }

    //
    // Stops the core and removes everything the test owns.
    //
    pub fn stop(self: *TestApp) void {
        self.core.destroy();
        process_env.setEnvironMap(null);
        utils.console.setCapture(null, null);
        self.console_out.deinit();
        self.console_err.deinit();
        self.environ_map.deinit();
        std.testing.allocator.free(self.tmp_path);
        std.testing.allocator.free(self.tasks);
        if (self.last_pick_title) |text| {
            std.testing.allocator.free(text);
        }
        if (self.last_host_method) |text| {
            std.testing.allocator.free(text);
        }
        if (self.last_host_request) |text| {
            std.testing.allocator.free(text);
        }
        if (self.last_pick_initial) |text| {
            std.testing.allocator.free(text);
        }
        self.tmp.cleanup();
        self.shell.deinit();
    }

    //
    // Sends a request on a channel with the data (JSON text) and waits for its reply, which it returns as the JSON text of the
    // whole reply message ({"id":..,"ok":..,"data":..} or {"id":..,"ok":false,"error":..}). The caller frees it.
    //
    pub fn request(self: *TestApp, channel: []const u8, data_json: []const u8) ![]u8 {
        const allocator = std.testing.allocator;
        const id = self.next_request_id;
        self.next_request_id += 1;
        const message = try std.fmt.allocPrint(allocator, "{{\"id\":{d},\"channel\":\"{s}\",\"data\":{s}}}", .{ id, channel, data_json });
        defer allocator.free(message);
        self.core.postMessage(message);
        const reply_start = try std.fmt.allocPrint(allocator, "{{\"id\":{d},\"ok\":", .{id});
        defer allocator.free(reply_start);
        try self.shell.expectMessageContaining(reply_start);
        return try self.shell.messageAt(allocator, self.shell.indexOfContaining(reply_start).?);
    }

    //
    // Sends a request that is expected to succeed and returns the JSON text of the reply's data. The caller frees it.
    //
    pub fn requestOk(self: *TestApp, channel: []const u8, data_json: []const u8) ![]u8 {
        const allocator = std.testing.allocator;
        const reply = try self.request(channel, data_json);
        defer allocator.free(reply);
        const marker = ",\"ok\":true,\"data\":";
        const marker_at = std.mem.indexOf(u8, reply, marker) orelse {
            std.debug.print("the request on {s} did not succeed: {s}\n", .{ channel, reply });
            return error.RequestFailed;
        };
        const data_start = marker_at + marker.len;
        return try allocator.dupe(u8, reply[data_start .. reply.len - 1]);
    }

    //
    // Sends a request that is expected to fail and returns the text of the reply's error. The caller frees it.
    //
    pub fn requestError(self: *TestApp, channel: []const u8, data_json: []const u8) ![]u8 {
        const allocator = std.testing.allocator;
        const reply = try self.request(channel, data_json);
        defer allocator.free(reply);
        const marker = ",\"ok\":false,\"error\":";
        const marker_at = std.mem.indexOf(u8, reply, marker) orelse {
            std.debug.print("the request on {s} did not fail: {s}\n", .{ channel, reply });
            return error.RequestSucceeded;
        };
        const error_json = reply[marker_at + marker.len .. reply.len - 1];
        var parsed = try std.json.parseFromSlice([]const u8, allocator, error_json, .{});
        defer parsed.deinit();
        return try allocator.dupe(u8, parsed.value);
    }
};

//
// The dialog callback of a test app: records what the dialog was asked and answers with the test app's pick_answer.
//
fn recordingPick(user_data: ?*anyopaque, kind: i32, title: ?[*:0]const u8, initial_name: ?[*:0]const u8, buffer: [*]u8, capacity: usize) callconv(.c) isize {
    const shell: *ziggy.fake_shell.FakeShell = @ptrCast(@alignCast(user_data.?));
    const app: *TestApp = @fieldParentPtr("shell", shell);
    app.last_pick_kind = kind;
    if (app.last_pick_title) |old| {
        std.testing.allocator.free(old);
    }
    app.last_pick_title = if (title) |text| std.testing.allocator.dupe(u8, std.mem.span(text)) catch @panic("out of memory") else null;
    if (app.last_pick_initial) |old| {
        std.testing.allocator.free(old);
    }
    app.last_pick_initial = if (initial_name) |text| std.testing.allocator.dupe(u8, std.mem.span(text)) catch @panic("out of memory") else null;
    if (capacity < app.pick_answer.len) {
        return -1;
    }
    @memcpy(buffer[0..app.pick_answer.len], app.pick_answer);
    return @intCast(app.pick_answer.len);
}

//
// Makes the core behave as it does on a platform whose shell has no host request callback, as every desktop does.
//
pub fn removeHostRequest(app: *TestApp) void {
    app.core.config.host_request = null;
    app.core.runner.config.host_request = null;
}

//
// The host request callback of a test app: records the method and the request and answers with the test app's host_answer, or fails with it.
//
fn recordingHostRequest(user_data: ?*anyopaque, method: [*:0]const u8, request_json: [*:0]const u8, buffer: [*]u8, capacity: usize) callconv(.c) isize {
    const shell: *ziggy.fake_shell.FakeShell = @ptrCast(@alignCast(user_data.?));
    const app: *TestApp = @fieldParentPtr("shell", shell);
    if (app.last_host_method) |old| {
        std.testing.allocator.free(old);
    }
    app.last_host_method = std.testing.allocator.dupe(u8, std.mem.span(method)) catch @panic("out of memory");
    if (app.last_host_request) |old| {
        std.testing.allocator.free(old);
    }
    app.last_host_request = std.testing.allocator.dupe(u8, std.mem.span(request_json)) catch @panic("out of memory");
    if (capacity < app.host_answer.len) {
        return -1;
    }
    @memcpy(buffer[0..app.host_answer.len], app.host_answer);
    const length: isize = @intCast(app.host_answer.len);
    return if (app.host_fails) -length else length;
}
