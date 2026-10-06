//
// The test control connection. It exists only in a build made with the test-hooks option, and lets a test script send
// commands to the running app over a loopback connection.
//
// A script connects to the port found in the port file and sends one line per command: a JSON object with a "command"
// field. The core forwards the command to the page as a test-command event, the page performs it and answers on the
// test-result channel, and the answer is written back as one line. A line that is not a command is answered with an
// error.
//

const std = @import("std");
const types = @import("types.zig");
const json_util = @import("json-util.zig");

//
// How long the page has to answer a command, in milliseconds.
//
const answer_timeout_ms: i64 = 30_000;

//
// One connection being served: the task serving it and its socket.
//
const Connection = struct {
    // The task that reads this connection's commands, cancelled when the control is stopped.
    task: std.Io.Future(void),
    // The connection's socket, closed when the control is stopped.
    stream: std.Io.net.Stream,
};

//
// The control connection of one core.
//
pub const TestControl = struct {
    // Allocates the lines it builds.
    allocator: std.mem.Allocator,
    // For the socket, the mutex and the condition.
    io: std.Io,
    // The shell's configuration, for the quit callback.
    config: types.ZiggyConfig,
    // Sends an event to the page.
    deliver: *const fn (user_data: ?*anyopaque, message: []const u8) void,
    // The pointer passed to deliver.
    deliver_user_data: ?*anyopaque,
    // Records the files of a drop, as the shell does when the user drops them. Called with deliver_user_data.
    files_dropped: *const fn (user_data: ?*anyopaque, paths_json: []const u8) anyerror!void,
    // The listening socket.
    server: std.Io.net.Server,
    // The port it listens on.
    port: u16,
    // One connection being served: its task and its socket.
    // Every connection is served by a task of its own, and all of them are ended when the control is stopped.
    connections: std.ArrayList(Connection),
    // Runs the connection tasks. The core's Io is single threaded and ignores cancel requests, and cancelling is the only way
    // to end a read that is waiting on a connection: on Windows shutting the socket down does not wake the read.
    connection_threaded: std.Io.Threaded,
    // Held while a command is with the page, so only one is waiting for an answer at a time.
    command_mutex: std.Io.Mutex,
    // The thread that accepts connections.
    thread: std.Thread,
    // Set when the connection is being shut down.
    stopping: std.atomic.Value(bool),
    // Guards the fields below.
    mutex: std.Io.Mutex,
    // The number of the next command.
    next_request: u64,
    // The number of the command waiting for an answer, or null.
    waiting_request: ?u64,
    // The answer to the waiting command, as JSON text.
    answer: ?[]u8,
    // Set when the page has said it is listening for test commands.
    page_ready: std.atomic.Value(bool),
    // What a test has said the next native dialog returns, as the JSON text of an array of paths, until a dialog takes it. Guarded
    // by mutex.
    pick_answer: ?[]u8,

    //
    // Starts listening on a loopback port the operating system chooses, writes the port to the port file when there is
    // one, and starts the thread that serves connections. It must stay where it is: the thread holds its address.
    //
    pub fn start(self: *TestControl, allocator: std.mem.Allocator, io: std.Io, config: types.ZiggyConfig, deliver: *const fn (user_data: ?*anyopaque, message: []const u8) void, deliver_user_data: ?*anyopaque, files_dropped: *const fn (user_data: ?*anyopaque, paths_json: []const u8) anyerror!void) !void {
        const address = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
        const server = try address.listen(io, .{});
        self.* = .{
            .allocator = allocator,
            .io = io,
            .config = config,
            .deliver = deliver,
            .deliver_user_data = deliver_user_data,
            .files_dropped = files_dropped,
            .server = server,
            .port = server.socket.address.getPort(),
            .thread = undefined,
            .stopping = .init(false),
            .connections = .empty,
            .connection_threaded = .init(allocator, .{}),
            .command_mutex = .init,
            .mutex = .init,
            .next_request = 1,
            .waiting_request = null,
            .answer = null,
            .page_ready = .init(false),
            .pick_answer = null,
        };
        errdefer self.server.deinit(io);
        errdefer self.connection_threaded.deinit();
        if (config.test_port_file) |port_file| {
            var port_buffer: [16]u8 = undefined;
            const port_text = try std.fmt.bufPrint(&port_buffer, "{d}\n", .{self.port});
            try std.Io.Dir.cwd().writeFile(io, .{
                .sub_path = std.mem.span(port_file),
                .data = port_text,
            });
        }
        self.thread = try std.Thread.spawn(.{}, serve, .{self});
    }

    //
    // Stops accepting connections, waits for the thread to end and releases everything.
    //
    pub fn stop(self: *TestControl) void {
        self.stopping.store(true, .release);
        // Accepting blocks, so a connection made here wakes the thread to see it has been told to stop.
        const address = std.Io.net.IpAddress.parseIp4("127.0.0.1", self.port) catch unreachable;
        if (address.connect(self.io, .{ .mode = .stream })) |stream| {
            stream.close(self.io);
        }
        else |_| {}
        self.thread.join();
        for (self.connections.items) |*connection| {
            connection.task.cancel(self.connection_threaded.io());
            connection.stream.close(self.io);
        }
        self.connections.deinit(self.allocator);
        self.connection_threaded.deinit();
        self.server.deinit(self.io);
        self.mutex.lockUncancelable(self.io);
        if (self.pick_answer) |text| {
            self.allocator.free(text);
        }
        if (self.answer) |text| {
            self.allocator.free(text);
        }
        self.mutex.unlock(self.io);
    }

    //
    // Called when the page answers a command on the test-result channel.
    //
    //
    // Called by a task that is about to show a native dialog: takes the answer a test gave for it, copied with the allocator, or
    // returns null when the test gave none, and the dialog is shown.
    //
    pub fn takePickAnswer(user_data: ?*anyopaque, allocator: std.mem.Allocator) ?[]u8 {
        const self: *TestControl = @ptrCast(@alignCast(user_data.?));
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const answer = self.pick_answer orelse {
            return null;
        };
        self.pick_answer = null;
        defer self.allocator.free(answer);
        return allocator.dupe(u8, answer) catch @panic("out of memory taking the answer for a dialog");
    }

    //
    // Called when the page says it is listening for test commands. A command sent before that would reach a page that is
    // not there to hear it, so commands wait for this.
    //
    pub fn markPageReady(self: *TestControl) void {
        self.page_ready.store(true, .release);
    }

    //
    // Waits until the page has said it is listening, or fails with PageDidNotAnswer when it never does.
    //
    fn waitForPage(self: *TestControl) !void {
        const deadline = std.Io.Clock.awake.now(self.io).addDuration(.fromMilliseconds(answer_timeout_ms));
        while (!self.page_ready.load(.acquire)) {
            if (std.Io.Clock.awake.now(self.io).durationTo(deadline).nanoseconds <= 0) {
                return error.PageDidNotAnswer;
            }
            self.io.sleep(.fromMilliseconds(5), .awake) catch @panic("sleep cancelled");
        }
    }

    pub fn setAnswer(self: *TestControl, request: u64, answer_json: []const u8) !void {
        const copy = try self.allocator.dupe(u8, answer_json);
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.waiting_request == null or self.waiting_request.? != request) {
            self.allocator.free(copy);
            return error.UnexpectedTestResult;
        }
        if (self.answer) |text| {
            self.allocator.free(text);
        }
        self.answer = copy;
    }

    fn serve(self: *TestControl) void {
        while (!self.stopping.load(.acquire)) {
            const stream = self.server.accept(self.io) catch {
                continue;
            };
            if (self.stopping.load(.acquire)) {
                stream.close(self.io);
                return;
            }
            const task = self.connection_threaded.io().concurrent(serveConnection, .{ self, stream }) catch |err| {
                std.debug.print("test control: could not serve a connection: {s}\n", .{@errorName(err)});
                stream.close(self.io);
                continue;
            };
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            self.connections.append(self.allocator, .{
                .task = task,
                .stream = stream,
            }) catch @panic("out of memory serving a test control connection");
        }
    }

    //
    // Serves one connection's commands until it closes or the control is stopped. Stopping cancels this task, and the cancel is
    // taken only while waiting for the next line: the command being run finishes first, because the waits inside it treat a
    // cancel as a bug.
    //
    fn serveConnection(self: *TestControl, stream: std.Io.net.Stream) void {
        const connection_io = self.connection_threaded.io();
        _ = connection_io.swapCancelProtection(.blocked);
        var read_buffer: [64 * 1024]u8 = undefined;
        var write_buffer: [1024]u8 = undefined;
        var reader = stream.reader(connection_io, &read_buffer);
        var writer = stream.writer(connection_io, &write_buffer);
        while (true) {
            _ = connection_io.swapCancelProtection(.unblocked);
            const taken = reader.interface.takeDelimiter('\n');
            _ = connection_io.swapCancelProtection(.blocked);
            const line = taken catch {
                return;
            } orelse {
                return;
            };
            const answer = self.handleLine(line) catch |err| blk: {
                const text = std.fmt.allocPrint(self.allocator, "{{\"error\":\"{s}\"}}", .{@errorName(err)}) catch {
                    return;
                };
                break :blk text;
            };
            defer self.allocator.free(answer);
            writer.interface.writeAll(answer) catch {
                return;
            };
            writer.interface.writeAll("\n") catch {
                return;
            };
            writer.interface.flush() catch {
                return;
            };
        }
    }

    //
    // Runs one command, a line holding a JSON object with a "command" field, and returns the answer line, allocated with
    // the allocator. A line that is not such an object is answered with an InvalidCommand error and nothing is run.
    //
    fn handleLine(self: *TestControl, line: []const u8) ![]u8 {
        const command_json = line;
        var arena_state = std.heap.ArenaAllocator.init(self.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const command = std.json.parseFromSliceLeaky(std.json.Value, arena, command_json, .{}) catch {
            return try self.allocator.dupe(u8, "{\"error\":\"InvalidCommand\"}");
        };
        const name = json_util.getString(command, "command") orelse {
            return try self.allocator.dupe(u8, "{\"error\":\"InvalidCommand\"}");
        };
        if (std.mem.eql(u8, name, "quit")) {
            const quit = self.config.quit orelse {
                return try self.allocator.dupe(u8, "{\"error\":\"HostCallbackMissing\"}");
            };
            quit(self.config.user_data);
            return try self.allocator.dupe(u8, "{\"ok\":true}");
        }
        if (std.mem.eql(u8, name, "menu")) {
            // Chooses a menu item as a user would, through the shell, so the shell's own actions really happen. Reloading unloads the
            // page, which is not listening again until it says so, so commands wait for that.
            const action = json_util.getString(command, "action") orelse {
                return try self.allocator.dupe(u8, "{\"error\":\"InvalidCommand\"}");
            };
            const choose = self.config.menu_action orelse {
                return try self.allocator.dupe(u8, "{\"error\":\"HostCallbackMissing\"}");
            };
            try self.waitForPage();
            if (std.mem.eql(u8, action, "reload")) {
                self.page_ready.store(false, .release);
            }
            const action_text = try arena.dupeZ(u8, action);
            choose(self.config.user_data, action_text.ptr);
            return try self.allocator.dupe(u8, "{\"ok\":true}");
        }
        if (std.mem.eql(u8, name, "drop")) {
            // Records a drop of files, as the shell does when the user drops files on the window, so a test can use getPathForFile
            // without dragging anything. The files are the command's "paths", an array of strings.
            const paths = command.object.get("paths") orelse {
                return try self.allocator.dupe(u8, "{\"error\":\"InvalidCommand\"}");
            };
            const paths_json = try json_util.stringify(arena, paths);
            self.files_dropped(self.deliver_user_data, paths_json) catch |err| {
                return try std.fmt.allocPrint(self.allocator, "{{\"error\":\"{s}\"}}", .{@errorName(err)});
            };
            return try self.allocator.dupe(u8, "{\"ok\":true}");
        }
        if (std.mem.eql(u8, name, "pick-answer")) {
            // Says what the next native dialog returns, so a test can use the pickers without a dialog being shown. The answer is
            // the command's "paths", an array of strings, and answers one dialog.
            const paths = command.object.get("paths") orelse {
                return try self.allocator.dupe(u8, "{\"error\":\"InvalidCommand\"}");
            };
            if (paths != .array) {
                return try self.allocator.dupe(u8, "{\"error\":\"InvalidCommand\"}");
            }
            for (paths.array.items) |item| {
                if (item != .string) {
                    return try self.allocator.dupe(u8, "{\"error\":\"InvalidCommand\"}");
                }
            }
            const answer = try json_util.stringify(self.allocator, paths);
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            if (self.pick_answer) |old| {
                self.allocator.free(old);
            }
            self.pick_answer = answer;
            return try self.allocator.dupe(u8, "{\"ok\":true}");
        }
        try self.waitForPage();
        return try self.askPage(arena, command_json);
    }

    //
    // Sends a command to the page and waits for its answer.
    //
    fn askPage(self: *TestControl, arena: std.mem.Allocator, command_json: []const u8) ![]u8 {
        self.command_mutex.lockUncancelable(self.io);
        defer self.command_mutex.unlock(self.io);
        self.mutex.lockUncancelable(self.io);
        const request = self.next_request;
        self.next_request += 1;
        self.waiting_request = request;
        if (self.answer) |text| {
            self.allocator.free(text);
            self.answer = null;
        }
        self.mutex.unlock(self.io);
        const event = try std.fmt.allocPrint(arena, "{{\"channel\":\"test-command\",\"data\":{{\"requestId\":{d},\"command\":{s}}}}}", .{ request, command_json });
        self.deliver(self.deliver_user_data, event);
        const deadline = std.Io.Clock.awake.now(self.io).addDuration(.fromMilliseconds(answer_timeout_ms));
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        defer self.waiting_request = null;
        while (self.answer == null) {
            const remaining = std.Io.Clock.awake.now(self.io).durationTo(deadline);
            if (remaining.nanoseconds <= 0) {
                return try self.allocator.dupe(u8, "{\"error\":\"PageDidNotAnswer\"}");
            }
            self.waitAnswer(remaining);
        }
        const answer = self.answer.?;
        self.answer = null;
        return answer;
    }

    fn waitAnswer(self: *TestControl, remaining: std.Io.Duration) void {
        // The condition has no timed wait, so the lock is released and retaken around a short sleep.
        _ = remaining;
        self.mutex.unlock(self.io);
        self.io.sleep(.fromMilliseconds(5), .awake) catch @panic("sleep cancelled");
        self.mutex.lockUncancelable(self.io);
    }
};
