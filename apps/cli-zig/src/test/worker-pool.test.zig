const std = @import("std");
const cli = @import("cli-zig");
const utils = @import("utils-zig");
const node_utils = @import("node-utils-zig");
const helpers = @import("test-helpers.zig");
const task_queue = @import("ziggy").task_queue;
const media_tools = @import("media-tools-zig");
const WorkerPoolBun = cli.worker_pool.WorkerPoolBun;
const types = task_queue.types;

//
// The results collected by the completion callback of a test.
//
pub const Collector = struct {
    // Guards the fields.
    mutex: std.Io.Mutex = .init,

    // The allocator the text of each result is copied into (the arena of the test, which outlives the
    // collector). The text is copied because it belongs to the result, which the worker frees as soon as
    // it has sent it, and it is not kept in a fixed buffer because its length is not known here: the error
    // the worker reports for an unregistered task type lists every handler registered in the process, so it
    // grows with every handler registered anywhere, and a fixed buffer overflowed and took the whole test
    // binary down.
    allocator: std.mem.Allocator,

    // Number of completed tasks.
    completed: usize = 0,

    // Number of failed tasks.
    failed: usize = 0,

    // The error message of the last failed task.
    lastErrorMessage: []const u8 = &.{},

    // The error name of the last failed task.
    lastErrorName: []const u8 = &.{},

    // The string output of the last successful task.
    lastOutput: []const u8 = &.{},

    // Number of messages received by the typed message callback.
    typedMessages: usize = 0,

    // Number of messages received by the any-message callback.
    anyMessages: usize = 0,

    // Number of tasks added (onTaskAdded).
    added: usize = 0,

    // Number of cancellations (onTasksCancelled).
    cancellations: usize = 0,

    //
    // Creates a collector that copies the text of each result into the allocator.
    //
    pub fn init(allocator: std.mem.Allocator) Collector {
        return .{
            .allocator = allocator,
        };
    }

    //
    // The completion callback.
    //
    pub fn onComplete(context: ?*anyopaque, result: types.ITaskResult) anyerror!void {
        const self: *Collector = @ptrCast(@alignCast(context.?));
        self.mutex.lockUncancelable(std.testing.io);
        defer self.mutex.unlock(std.testing.io);
        self.completed += 1;
        if (result.status == .Failed) {
            self.failed += 1;
            const message = result.errorMessage orelse "";
            self.lastErrorMessage = try self.allocator.dupe(u8, message);
            const name = result.@"error".?.name;
            self.lastErrorName = try self.allocator.dupe(u8, name);
        }
        else {
            if (result.outputs) |outputs| {
                if (outputs == .string) {
                    self.lastOutput = try self.allocator.dupe(u8, outputs.string);
                }
            }
        }
    }

    //
    // The typed message callback.
    //
    fn onTypedMessage(context: ?*anyopaque, data: types.ITaskMessageData) anyerror!void {
        const self: *Collector = @ptrCast(@alignCast(context.?));
        self.mutex.lockUncancelable(std.testing.io);
        defer self.mutex.unlock(std.testing.io);
        self.typedMessages += 1;
        _ = data;
    }

    //
    // The any-message callback.
    //
    fn onAnyMessage(context: ?*anyopaque, data: types.ITaskMessageData) anyerror!void {
        const self: *Collector = @ptrCast(@alignCast(context.?));
        self.mutex.lockUncancelable(std.testing.io);
        defer self.mutex.unlock(std.testing.io);
        self.anyMessages += 1;
        _ = data;
    }

    //
    // The onTaskAdded callback.
    //
    fn onAdded(context: ?*anyopaque, taskId: []const u8) void {
        const self: *Collector = @ptrCast(@alignCast(context.?));
        _ = taskId;
        self.added += 1;
    }

    //
    // The onTasksCancelled callback.
    //
    fn onCancelled(context: ?*anyopaque) void {
        const self: *Collector = @ptrCast(@alignCast(context.?));
        self.cancellations += 1;
    }

    //
    // Waits until the number of completed tasks reaches the count (fails after 10 seconds).
    //
    pub fn waitForCompleted(self: *Collector, count: usize) !void {
        var waited: usize = 0;
        while (waited < 2000) {
            self.mutex.lockUncancelable(std.testing.io);
            const completed = self.completed;
            self.mutex.unlock(std.testing.io);
            if (completed >= count) {
                return;
            }
            std.testing.io.sleep(.fromMilliseconds(5), .awake) catch {};
            waited += 1;
        }
        return error.TestTimedOut;
    }
};

//
// Returns the text of the task data.
//
fn echoHandler(allocator: std.mem.Allocator, io: std.Io, data: std.json.Value, context: types.ITaskContext) anyerror!std.json.Value {
    _ = io;
    _ = context;
    return .{ .string = try std.fmt.allocPrint(allocator, "echo {s}", .{data.string}) };
}

//
// Always fails.
//
fn failingHandler(allocator: std.mem.Allocator, io: std.Io, data: std.json.Value, context: types.ITaskContext) anyerror!std.json.Value {
    _ = allocator;
    _ = io;
    _ = data;
    _ = context;
    return utils.errors.throwError("boom {d}", .{42});
}

//
// Sends two messages, one of type "progress".
//
fn messagingHandler(allocator: std.mem.Allocator, io: std.Io, data: std.json.Value, context: types.ITaskContext) anyerror!std.json.Value {
    _ = io;
    _ = data;
    var progress: std.json.ObjectMap = .empty;
    try progress.put(allocator, "type", .{ .string = "progress" });
    context.sendMessage(.{ .object = progress });
    var other: std.json.ObjectMap = .empty;
    try other.put(allocator, "type", .{ .string = "other" });
    context.sendMessage(.{ .object = other });
    return .null;
}

//
// Number of blocking tasks running at the same time, and the maximum seen.
//
var running_now: std.atomic.Value(usize) = .init(0);

//
// The maximum number of blocking tasks that ran at the same time.
//
var running_max: std.atomic.Value(usize) = .init(0);

//
// Set to release the blocking tasks.
//
var release_blocked: std.atomic.Value(bool) = .init(false);

//
// Blocks until released (or cancelled), tracking concurrency.
//
fn blockingHandler(allocator: std.mem.Allocator, io: std.Io, data: std.json.Value, context: types.ITaskContext) anyerror!std.json.Value {
    _ = allocator;
    _ = data;
    const now = running_now.fetchAdd(1, .acq_rel) + 1;
    _ = running_max.fetchMax(now, .acq_rel);
    defer _ = running_now.fetchSub(1, .acq_rel);
    while (!release_blocked.load(.acquire) and !context.isCancelled()) {
        io.sleep(.fromMilliseconds(2), .awake) catch {};
    }
    return .null;
}

//
// Sleeps longer than the timeout of the timeout test.
//
fn slowHandler(allocator: std.mem.Allocator, io: std.Io, data: std.json.Value, context: types.ITaskContext) anyerror!std.json.Value {
    _ = allocator;
    _ = data;
    _ = context;
    io.sleep(.fromMilliseconds(300), .awake) catch {};
    return .null;
}

//
// Runs `magick -version` through the tool runner of the task's context and returns what it printed. Fails when the
// context has no runner, rather than starting an installed program.
//
fn magickVersionHandler(allocator: std.mem.Allocator, io: std.Io, data: std.json.Value, context: types.ITaskContext) anyerror!std.json.Value {
    _ = data;
    const toolRunner = context.toolRunner orelse return utils.errors.throwError("The task was given no tool runner.", .{});
    const result = try node_utils.exec.exec(allocator, io, toolRunner, "magick -version");
    return .{ .string = result.stdout };
}

//
// The video the `ffmpeg` handlers read, relative to apps/cli-zig, where the tests run.
//
const test_video = "../../test/multiple-files/test.mp4";

//
// Runs an `ffmpeg` that never ends on its own through the tool runner of the task's context: the video is read over and over
// and encoded to the `null` muxer, with `mjpeg` (the one encoder the built-in FFmpeg has) and the audio dropped. Only a stop
// ends it.
//
fn endlessFfmpegHandler(allocator: std.mem.Allocator, io: std.Io, data: std.json.Value, context: types.ITaskContext) anyerror!std.json.Value {
    _ = data;
    const toolRunner = context.toolRunner orelse return utils.errors.throwError("The task was given no tool runner.", .{});
    _ = try node_utils.exec.exec(allocator, io, toolRunner, "ffmpeg -stream_loop -1 -i \"" ++ test_video ++ "\" -an -c:v mjpeg -f null -");
    return .null;
}

//
// Writes the first frame of the video as a JPEG to the path in the task data, through the tool runner of the task's context.
//
fn oneFrameFfmpegHandler(allocator: std.mem.Allocator, io: std.Io, data: std.json.Value, context: types.ITaskContext) anyerror!std.json.Value {
    const toolRunner = context.toolRunner orelse return utils.errors.throwError("The task was given no tool runner.", .{});
    const command = try std.fmt.allocPrint(allocator, "ffmpeg -i \"" ++ test_video ++ "\" -frames:v 1 -y \"{s}\"", .{data.string});
    _ = try node_utils.exec.exec(allocator, io, toolRunner, command);
    return .{ .string = "frame written" };
}

//
// Registers the handlers of the tests.
//
fn registerHandlers() !void {
    try task_queue.worker.registerHandler("echo", echoHandler);
    try task_queue.worker.registerHandler("fail", failingHandler);
    try task_queue.worker.registerHandler("message", messagingHandler);
    try task_queue.worker.registerHandler("block", blockingHandler);
    try task_queue.worker.registerHandler("slow", slowHandler);
    try task_queue.worker.registerHandler("magick-version", magickVersionHandler);
    try task_queue.worker.registerHandler("endless-ffmpeg", endlessFfmpegHandler);
    try task_queue.worker.registerHandler("one-frame-ffmpeg", oneFrameFfmpegHandler);
}

test "runs a task on a worker and reports its outputs" {
    try registerHandlers();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // The pool installs the worker log routing in place of the global log; put the global log back after.
    const previousLog = utils.log.log;
    defer utils.log.setLog(previousLog);
    var mediaTools = try media_tools.MediaTools.init(std.testing.io);
    defer mediaTools.deinit();
    const pool = try WorkerPoolBun.init(std.testing.io, &mediaTools, 2, 10000, .{ .sessionId = "session" });
    defer pool.deinit();
    const backend = pool.queueBackend();
    var collector = Collector.init(arena.allocator());
    _ = try backend.onTaskComplete(.{ .context = &collector, .function = Collector.onComplete });
    const taskId = try backend.addTask(arena.allocator(), std.testing.io, "echo", .{ .string = "hi" }, "source", "task-1", null);
    try std.testing.expectEqualStrings("task-1", taskId);
    try collector.waitForCompleted(1);
    try std.testing.expectEqual(@as(usize, 0), collector.failed);
    try std.testing.expectEqualStrings("echo hi", collector.lastOutput);
}

test "a worker that fails to start is logged and replaced, and its task waits" {
    try registerHandlers();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // The test UUID generator keeps its counter under TEST_TMP_DIR: below a file, that directory cannot be
    // created, so generating the session ID of every worker fails.
    const root = try helpers.makeTempDir(allocator, "worker-pool-start-failure");
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    const blockingFile = try std.fs.path.join(allocator, &.{ root, "file" });
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = blockingFile, .data = "x" });
    var environ_map = std.process.Environ.Map.init(allocator);
    try environ_map.put("NODE_ENV", "testing");
    try environ_map.put("TEST_TMP_DIR", try std.fs.path.join(allocator, &.{ blockingFile, "tmp" }));
    node_utils.process_env.setEnvironMap(&environ_map);
    defer node_utils.process_env.setEnvironMap(null);

    var stdout_capture = std.Io.Writer.Allocating.init(allocator);
    var stderr_capture = std.Io.Writer.Allocating.init(allocator);
    utils.console.setCapture(&stdout_capture.writer, &stderr_capture.writer);
    defer utils.console.setCapture(null, null);

    // The pool installs the worker log routing in place of the global log; put the global log back after.
    const previousLog = utils.log.log;
    defer utils.log.setLog(previousLog);
    var mediaTools = try media_tools.MediaTools.init(std.testing.io);
    defer mediaTools.deinit();
    const pool = try WorkerPoolBun.init(std.testing.io, &mediaTools, 1, 10000, .{});
    var collector = Collector.init(allocator);
    _ = try pool.onTaskComplete(.{ .context = &collector, .function = Collector.onComplete });
    _ = try pool.addTask(allocator, std.testing.io, "echo", .{ .string = "x" }, "source", null, null);
    std.testing.io.sleep(.fromMilliseconds(100), .awake) catch {};
    pool.deinit();

    try std.testing.expect(std.mem.indexOf(u8, stderr_capture.written(), "Error from worker 1\n") != null);
    try std.testing.expectEqual(@as(usize, 0), collector.completed);
}

test "generates a task ID when none is given" {
    try registerHandlers();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // The pool installs the worker log routing in place of the global log; put the global log back after.
    const previousLog = utils.log.log;
    defer utils.log.setLog(previousLog);
    var mediaTools = try media_tools.MediaTools.init(std.testing.io);
    defer mediaTools.deinit();
    const pool = try WorkerPoolBun.init(std.testing.io, &mediaTools, 1, 10000, .{});
    defer pool.deinit();
    var collector = Collector.init(arena.allocator());
    _ = try pool.onTaskComplete(.{ .context = &collector, .function = Collector.onComplete });
    const taskId = try pool.addTask(arena.allocator(), std.testing.io, "echo", .{ .string = "x" }, "source", null, null);
    try std.testing.expectEqual(@as(usize, 36), taskId.len);
    try collector.waitForCompleted(1);
}

test "reports a failed task with the error name and message" {
    try registerHandlers();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // The pool installs the worker log routing in place of the global log; put the global log back after.
    const previousLog = utils.log.log;
    defer utils.log.setLog(previousLog);
    var mediaTools = try media_tools.MediaTools.init(std.testing.io);
    defer mediaTools.deinit();
    const pool = try WorkerPoolBun.init(std.testing.io, &mediaTools, 1, 10000, .{});
    defer pool.deinit();
    var collector = Collector.init(arena.allocator());
    _ = try pool.onTaskComplete(.{ .context = &collector, .function = Collector.onComplete });
    _ = try pool.addTask(arena.allocator(), std.testing.io, "fail", .null, "source", null, null);
    _ = try pool.addTask(arena.allocator(), std.testing.io, "no-such-type", .null, "source", null, null);
    try collector.waitForCompleted(2);
    try std.testing.expectEqual(@as(usize, 2), collector.failed);
    try std.testing.expectEqualStrings("Error", collector.lastErrorName);
    try std.testing.expect(std.mem.startsWith(u8, collector.lastErrorMessage, "No handler registered for task type: no-such-type."));
}

test "forwards task messages to the message callbacks" {
    try registerHandlers();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // The pool installs the worker log routing in place of the global log; put the global log back after.
    const previousLog = utils.log.log;
    defer utils.log.setLog(previousLog);
    var mediaTools = try media_tools.MediaTools.init(std.testing.io);
    defer mediaTools.deinit();
    const pool = try WorkerPoolBun.init(std.testing.io, &mediaTools, 1, 10000, .{});
    defer pool.deinit();
    var collector = Collector.init(arena.allocator());
    _ = try pool.onTaskComplete(.{ .context = &collector, .function = Collector.onComplete });
    _ = try pool.onTaskMessage("progress", .{ .context = &collector, .function = Collector.onTypedMessage });
    const unsubscribe = try pool.onAnyTaskMessage(.{ .context = &collector, .function = Collector.onAnyMessage });
    _ = try pool.addTask(arena.allocator(), std.testing.io, "message", .null, "source", null, null);
    try collector.waitForCompleted(1);
    try std.testing.expectEqual(@as(usize, 1), collector.typedMessages);
    try std.testing.expectEqual(@as(usize, 2), collector.anyMessages);

    unsubscribe.call();
    _ = try pool.addTask(arena.allocator(), std.testing.io, "message", .null, "source", null, null);
    try collector.waitForCompleted(2);
    try std.testing.expectEqual(@as(usize, 2), collector.typedMessages);
    try std.testing.expectEqual(@as(usize, 2), collector.anyMessages);
}

test "creates workers lazily up to maxWorkers" {
    try registerHandlers();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    running_now.store(0, .release);
    running_max.store(0, .release);
    release_blocked.store(false, .release);
    // The pool installs the worker log routing in place of the global log; put the global log back after.
    const previousLog = utils.log.log;
    defer utils.log.setLog(previousLog);
    var mediaTools = try media_tools.MediaTools.init(std.testing.io);
    defer mediaTools.deinit();
    const pool = try WorkerPoolBun.init(std.testing.io, &mediaTools, 2, 10000, .{});
    defer pool.deinit();
    var collector = Collector.init(arena.allocator());
    _ = try pool.onTaskComplete(.{ .context = &collector, .function = Collector.onComplete });
    var index: usize = 0;
    while (index < 4) {
        _ = try pool.addTask(arena.allocator(), std.testing.io, "block", .null, "source", null, null);
        index += 1;
    }
    var waited: usize = 0;
    while (running_now.load(.acquire) < 2 and waited < 2000) {
        std.testing.io.sleep(.fromMilliseconds(5), .awake) catch {};
        waited += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), pool.workers.items.len);
    release_blocked.store(true, .release);
    try collector.waitForCompleted(4);
    try std.testing.expectEqual(@as(usize, 2), running_max.load(.acquire));
    try std.testing.expectEqual(@as(usize, 0), collector.failed);
}

test "times out a task, reports it failed and replaces the worker" {
    try registerHandlers();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var stdout_capture = std.Io.Writer.Allocating.init(allocator);
    var stderr_capture = std.Io.Writer.Allocating.init(allocator);
    utils.console.setCapture(&stdout_capture.writer, &stderr_capture.writer);
    defer utils.console.setCapture(null, null);

    // The pool installs the worker log routing in place of the global log; put the global log back after.
    const previousLog = utils.log.log;
    defer utils.log.setLog(previousLog);
    var mediaTools = try media_tools.MediaTools.init(std.testing.io);
    defer mediaTools.deinit();
    const pool = try WorkerPoolBun.init(std.testing.io, &mediaTools, 1, 50, .{});
    defer pool.deinit();
    var collector = Collector.init(allocator);
    _ = try pool.onTaskComplete(.{ .context = &collector, .function = Collector.onComplete });
    _ = try pool.addTask(allocator, std.testing.io, "slow", .null, "source", "slow-task", null);
    _ = try pool.addTask(allocator, std.testing.io, "echo", .{ .string = "after" }, "source", "echo-task", null);
    try collector.waitForCompleted(2);
    try std.testing.expectEqual(@as(usize, 1), collector.failed);
    try std.testing.expectEqualStrings("echo after", collector.lastOutput);
    try std.testing.expect(std.mem.indexOf(u8, stderr_capture.written(), "[Task Queue] Task slow-task timed out after 50ms\n") != null);
    try std.testing.expectEqual(@as(usize, 1), pool.workers.items.len);
    try std.testing.expectEqual(@as(u32, 1), pool.workers.items[0].workerId);
}

test "the timeout message writes the timeout as a template string writes a number" {
    try registerHandlers();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var stdout_capture = std.Io.Writer.Allocating.init(allocator);
    var stderr_capture = std.Io.Writer.Allocating.init(allocator);
    utils.console.setCapture(&stdout_capture.writer, &stderr_capture.writer);
    defer utils.console.setCapture(null, null);

    // The pool installs the worker log routing in place of the global log; put the global log back after.
    const previousLog = utils.log.log;
    defer utils.log.setLog(previousLog);
    // `--timeout 0.0000001`: the timer waits 1 ms, and the message writes the timeout as 1e-7.
    var mediaTools = try media_tools.MediaTools.init(std.testing.io);
    defer mediaTools.deinit();
    const pool = try WorkerPoolBun.init(std.testing.io, &mediaTools, 1, 1e-7, .{});
    defer pool.deinit();
    var collector = Collector.init(allocator);
    _ = try pool.onTaskComplete(.{ .context = &collector, .function = Collector.onComplete });
    _ = try pool.addTask(allocator, std.testing.io, "slow", .null, "source", "slow-task", null);
    try collector.waitForCompleted(1);
    try std.testing.expect(std.mem.indexOf(u8, stderr_capture.written(), "[Task Queue] Task slow-task timed out after 1e-7ms\n") != null);
}

test "cancelTasks drops pending tasks and signals running tasks" {
    try registerHandlers();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    running_now.store(0, .release);
    release_blocked.store(false, .release);
    // The pool installs the worker log routing in place of the global log; put the global log back after.
    const previousLog = utils.log.log;
    defer utils.log.setLog(previousLog);
    var mediaTools = try media_tools.MediaTools.init(std.testing.io);
    defer mediaTools.deinit();
    const pool = try WorkerPoolBun.init(std.testing.io, &mediaTools, 1, 10000, .{});
    defer pool.deinit();
    var collector = Collector.init(allocator);
    _ = try pool.onTaskComplete(.{ .context = &collector, .function = Collector.onComplete });
    _ = try pool.onTaskAdded("db", .{ .context = &collector, .function = Collector.onAdded });
    _ = try pool.onTasksCancelled("db", .{ .context = &collector, .function = Collector.onCancelled });
    _ = try pool.addTask(allocator, std.testing.io, "block", .null, "db", null, null);
    _ = try pool.addTask(allocator, std.testing.io, "block", .null, "db", null, null);
    _ = try pool.addTask(allocator, std.testing.io, "echo", .{ .string = "other" }, "other-source", null, null);
    try std.testing.expectEqual(@as(usize, 2), collector.added);
    var waited: usize = 0;
    while (running_now.load(.acquire) < 1 and waited < 2000) {
        std.testing.io.sleep(.fromMilliseconds(5), .awake) catch {};
        waited += 1;
    }
    pool.cancelTasks("db");
    try std.testing.expectEqual(@as(usize, 1), collector.cancellations);
    try collector.waitForCompleted(2);
    std.testing.io.sleep(.fromMilliseconds(50), .awake) catch {};
    try std.testing.expectEqual(@as(usize, 2), collector.completed);
    try std.testing.expectEqualStrings("echo other", collector.lastOutput);
}

test "shutdown terminates the workers" {
    try registerHandlers();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // The pool installs the worker log routing in place of the global log; put the global log back after.
    const previousLog = utils.log.log;
    defer utils.log.setLog(previousLog);
    var mediaTools = try media_tools.MediaTools.init(std.testing.io);
    defer mediaTools.deinit();
    const pool = try WorkerPoolBun.init(std.testing.io, &mediaTools, 2, 10000, .{});
    defer pool.deinit();
    var collector = Collector.init(arena.allocator());
    _ = try pool.onTaskComplete(.{ .context = &collector, .function = Collector.onComplete });
    _ = try pool.addTask(arena.allocator(), std.testing.io, "echo", .{ .string = "x" }, "source", null, null);
    try collector.waitForCompleted(1);
    pool.queueBackend().shutdown();
    try std.testing.expectEqual(@as(usize, 0), pool.workers.items.len);
}

test "a task is handed the runner of the tools built into the program" {
    try registerHandlers();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // The pool installs the worker log routing in place of the global log; put the global log back after.
    const previousLog = utils.log.log;
    defer utils.log.setLog(previousLog);
    var mediaTools = try media_tools.MediaTools.init(std.testing.io);
    defer mediaTools.deinit();
    const pool = try WorkerPoolBun.init(std.testing.io, &mediaTools, 1, 10000, .{});
    defer pool.deinit();
    var collector = Collector.init(arena.allocator());
    _ = try pool.onTaskComplete(.{ .context = &collector, .function = Collector.onComplete });
    _ = try pool.addTask(arena.allocator(), std.testing.io, "magick-version", .null, "source", null, null);
    try collector.waitForCompleted(1);
    try std.testing.expectEqualStrings("", collector.lastErrorMessage);
    try std.testing.expectEqual(@as(usize, 0), collector.failed);

    // What the task printed is the version of the ImageMagick built into the program, read here from the library itself.
    const builtInVersion = (try mediaTools.image_magick.runMagick(arena.allocator(), &.{"-version"})).output;
    try std.testing.expect(std.mem.indexOf(u8, builtInVersion, "Version: ImageMagick ") != null);
    try std.testing.expectEqualStrings(builtInVersion, collector.lastOutput);
}

//
// Ends the whole test program with a message. A stop that does not work leaves the endless `ffmpeg` running on its abandoned
// thread, holding the FFmpeg lock and FFmpeg's process-wide state, so the test cannot just fail: every later `ffmpeg` in this
// program would hang behind it, and the pool's deinit would wait for that thread for ever.
//
fn endTestProgram(message: []const u8) noreturn {
    std.debug.print("{s}\n", .{message});
    std.process.exit(1);
}

//
// Waits up to the number of seconds until the collector has seen the number of completed tasks, and says whether it did.
//
fn waitForCompletedWithin(collector: *Collector, count: usize, seconds: i64) bool {
    const io = std.testing.io;
    const deadline = std.Io.Clock.Timestamp.fromNow(io, .{
        .raw = std.Io.Duration.fromSeconds(seconds),
        .clock = .awake,
    });
    while (deadline.durationFromNow(io).raw.nanoseconds > 0) {
        collector.mutex.lockUncancelable(io);
        const completed = collector.completed;
        collector.mutex.unlock(io);
        if (completed >= count) {
            return true;
        }
        io.sleep(.fromMilliseconds(10), .awake) catch {};
    }
    return false;
}

test "a timed out task's ffmpeg is stopped, so a later ffmpeg through the pool runs" {
    try registerHandlers();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root = try helpers.makeTempDir(allocator, "worker-pool-ffmpeg-stop");
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    var stderr_capture = std.Io.Writer.Allocating.init(allocator);
    var stdout_capture = std.Io.Writer.Allocating.init(allocator);
    utils.console.setCapture(&stdout_capture.writer, &stderr_capture.writer);
    defer utils.console.setCapture(null, null);
    // The pool installs the worker log routing in place of the global log; put the global log back after.
    const previousLog = utils.log.log;
    defer utils.log.setLog(previousLog);
    var mediaTools = try media_tools.MediaTools.init(std.testing.io);
    defer mediaTools.deinit();
    const pool = try WorkerPoolBun.init(std.testing.io, &mediaTools, 1, 3000, .{});
    defer pool.deinit();
    var collector = Collector.init(allocator);
    _ = try pool.onTaskComplete(.{ .context = &collector, .function = Collector.onComplete });

    // The endless ffmpeg runs until the pool's timeout, which reports the task failed.
    _ = try pool.addTask(allocator, std.testing.io, "endless-ffmpeg", .null, "source", null, null);
    if (!waitForCompletedWithin(&collector, 1, 60)) {
        endTestProgram("The endless ffmpeg task was not reported within 60 seconds.");
    }
    try std.testing.expectEqual(@as(usize, 1), collector.failed);
    try std.testing.expectEqualStrings("Task timeout", collector.lastErrorMessage);

    // A later ffmpeg runs only when the timed out one was stopped: otherwise it waits on the FFmpeg lock for ever.
    const framePath = try std.fs.path.join(allocator, &.{ root, "frame.jpg" });
    _ = try pool.addTask(allocator, std.testing.io, "one-frame-ffmpeg", .{ .string = framePath }, "source", null, null);
    if (!waitForCompletedWithin(&collector, 2, 60)) {
        endTestProgram("The one frame ffmpeg task after the timed out one did not end within 60 seconds.");
    }

    // The pool's own timeout also ends a follow-up that waited on the FFmpeg lock. Either way, an ffmpeg still running here is
    // the timed out one, which was not stopped, and the pool's deinit would wait for its thread for ever.
    const stillRunning = running: {
        mediaTools.ffmpeg.stop_mutex.lockUncancelable(std.testing.io);
        defer mediaTools.ffmpeg.stop_mutex.unlock(std.testing.io);
        break :running mediaTools.ffmpeg.running_thread != null;
    };
    if (stillRunning) {
        endTestProgram(try std.fmt.allocPrint(allocator, "The timed out task's ffmpeg was not stopped: it still holds the FFmpeg lock, and the one frame ffmpeg task after it ended with \"{s}\".", .{collector.lastErrorMessage}));
    }
    try std.testing.expectEqual(@as(usize, 1), collector.failed);
    try std.testing.expectEqualStrings("frame written", collector.lastOutput);
    const frame = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, framePath, allocator, .unlimited);
    try std.testing.expect(std.mem.startsWith(u8, frame, "\xFF\xD8\xFF"));
}
