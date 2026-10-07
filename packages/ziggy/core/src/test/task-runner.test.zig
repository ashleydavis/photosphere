const std = @import("std");
const ziggy = @import("ziggy-core");
const helpers = @import("helpers.zig");

fn addTask(core: *ziggy.core.Core, id: []const u8, task_type: []const u8, source: []const u8, data: []const u8, priority: i32) !void {
    const message = try std.fmt.allocPrint(std.testing.allocator, "{{\"channel\":\"add-task\",\"data\":{{\"taskId\":\"{s}\",\"taskType\":\"{s}\",\"source\":\"{s}\",\"data\":{s},\"priority\":{d}}}}}", .{ id, task_type, source, data, priority });
    defer std.testing.allocator.free(message);
    core.postMessage(message);
}

fn cancelSource(core: *ziggy.core.Core, source: []const u8) !void {
    const message = try std.fmt.allocPrint(std.testing.allocator, "{{\"channel\":\"cancel-tasks\",\"data\":{{\"source\":\"{s}\"}}}}", .{source});
    defer std.testing.allocator.free(message);
    core.postMessage(message);
}


fn expectCompleted(shell: *helpers.FakeShell, id: []const u8, status: []const u8) !void {
    var buffer: [256]u8 = undefined;
    const text = try std.fmt.bufPrint(&buffer, "task-completed\",\"data\":{{\"taskId\":\"{s}\",", .{id});
    try shell.expectMessageContaining(text);
    const index = shell.indexOfContaining(text).?;
    const message = try shell.messageAt(std.testing.allocator, index);
    defer std.testing.allocator.free(message);
    var status_buffer: [64]u8 = undefined;
    const status_text = try std.fmt.bufPrint(&status_buffer, "\"status\":\"{s}\"", .{status});
    if (std.mem.indexOf(u8, message, status_text) == null) {
        std.debug.print("task {s} completed as: {s}\n", .{ id, message });
        return error.WrongStatus;
    }
}

test "a short task sends its message and completes as succeeded with its result" {
    var shell: helpers.FakeShell = undefined;
    shell.init(std.testing.allocator);
    defer shell.deinit();
    const core = try helpers.createCore(&shell, 2, 2);
    defer core.destroy();
    try addTask(core, "t1", "quick", "s", "null", 0);
    try shell.expectMessageContaining("\"status\":\"succeeded\",\"result\":\"done\"");
    const message_index = shell.indexOfContaining("\"channel\":\"task-message\"").?;
    const completed_index = shell.indexOfContaining("\"channel\":\"task-completed\"").?;
    try std.testing.expect(message_index < completed_index);
    const message = try shell.messageAt(std.testing.allocator, message_index);
    defer std.testing.allocator.free(message);
    try std.testing.expectEqualStrings("{\"channel\":\"task-message\",\"data\":{\"taskId\":\"t1\",\"source\":\"s\",\"message\":{\"text\":\"hello\"}}}", message);
}

test "a failing task completes as failed with its error" {
    var shell: helpers.FakeShell = undefined;
    shell.init(std.testing.allocator);
    defer shell.deinit();
    const core = try helpers.createCore(&shell, 1, 1);
    defer core.destroy();
    try addTask(core, "t1", "fail", "s", "null", 0);
    try shell.expectMessageContaining("\"status\":\"failed\",\"error\":\"TestFailure\"");
}

test "an unknown task type completes as failed" {
    var shell: helpers.FakeShell = undefined;
    shell.init(std.testing.allocator);
    defer shell.deinit();
    const core = try helpers.createCore(&shell, 1, 1);
    defer core.destroy();
    try addTask(core, "t1", "nothing-like-this", "s", "null", 0);
    try shell.expectMessageContaining("\"status\":\"failed\",\"error\":\"UnknownTaskType\"");
}

test "cancelling a running task stops it early and completes it as cancelled" {
    var shell: helpers.FakeShell = undefined;
    shell.init(std.testing.allocator);
    defer shell.deinit();
    const core = try helpers.createCore(&shell, 2, 2);
    defer core.destroy();
    try addTask(core, "t1", "spin", "s", "null", 0);
    try shell.expectMessageContaining("\"step\":3");
    try cancelSource(core, "s");
    try expectCompleted(&shell, "t1", "cancelled");
}

test "cancelling a queued task means it never starts" {
    var shell: helpers.FakeShell = undefined;
    shell.init(std.testing.allocator);
    defer shell.deinit();
    const core = try helpers.createCore(&shell, 1, 1);
    defer core.destroy();
    try addTask(core, "blocker", "sleep", "blocker-source", "{\"ms\":300,\"name\":\"blocker\"}", 0);
    try shell.expectMessageContaining("\"start\":\"blocker\"");
    try addTask(core, "queued", "sleep", "queued-source", "{\"ms\":10,\"name\":\"queued\"}", 0);
    try cancelSource(core, "queued-source");
    try expectCompleted(&shell, "queued", "cancelled");
    try expectCompleted(&shell, "blocker", "succeeded");
    try std.testing.expectEqual(@as(usize, 0), shell.countContaining("\"start\":\"queued\""));
}

test "cancelling one source leaves another source's tasks running" {
    var shell: helpers.FakeShell = undefined;
    shell.init(std.testing.allocator);
    defer shell.deinit();
    const core = try helpers.createCore(&shell, 3, 2);
    defer core.destroy();
    try addTask(core, "a", "spin", "source-a", "null", 0);
    try addTask(core, "b", "spin", "source-b", "null", 0);
    try shell.expectMessageContaining("\"taskId\":\"a\",\"source\":\"source-a\",\"message\":{\"step\":2}");
    try shell.expectMessageContaining("\"taskId\":\"b\",\"source\":\"source-b\",\"message\":{\"step\":2}");
    try cancelSource(core, "source-a");
    try expectCompleted(&shell, "a", "cancelled");
    shell.sleepMs(50);
    try std.testing.expectEqual(@as(usize, 0), shell.countContaining("\"taskId\":\"b\",\"source\":\"source-b\",\"status\""));
    try cancelSource(core, "source-b");
    try expectCompleted(&shell, "b", "cancelled");
}

test "a task queued under a source after it was cancelled is not cancelled" {
    var shell: helpers.FakeShell = undefined;
    shell.init(std.testing.allocator);
    defer shell.deinit();
    const core = try helpers.createCore(&shell, 2, 2);
    defer core.destroy();
    try addTask(core, "first", "spin", "s", "null", 0);
    try shell.expectMessageContaining("\"step\":1");
    try cancelSource(core, "s");
    try expectCompleted(&shell, "first", "cancelled");
    try addTask(core, "second", "quick", "s", "null", 0);
    try expectCompleted(&shell, "second", "succeeded");
}

test "a cancel for an unknown source is harmless" {
    var shell: helpers.FakeShell = undefined;
    shell.init(std.testing.allocator);
    defer shell.deinit();
    const core = try helpers.createCore(&shell, 1, 1);
    defer core.destroy();
    try cancelSource(core, "nobody");
    try addTask(core, "t1", "quick", "s", "null", 0);
    try expectCompleted(&shell, "t1", "succeeded");
}

test "a higher priority task starts before a lower priority one queued earlier" {
    var shell: helpers.FakeShell = undefined;
    shell.init(std.testing.allocator);
    defer shell.deinit();
    const core = try helpers.createCore(&shell, 1, 1);
    defer core.destroy();
    try addTask(core, "blocker", "sleep", "s", "{\"ms\":150,\"name\":\"blocker\"}", 0);
    try shell.expectMessageContaining("\"start\":\"blocker\"");
    try addTask(core, "low", "sleep", "s", "{\"ms\":5,\"name\":\"low\"}", 1);
    try addTask(core, "high", "sleep", "s", "{\"ms\":5,\"name\":\"high\"}", 9);
    try expectCompleted(&shell, "low", "succeeded");
    try expectCompleted(&shell, "high", "succeeded");
    const high = shell.indexOfContaining("\"start\":\"high\"").?;
    const low = shell.indexOfContaining("\"start\":\"low\"").?;
    try std.testing.expect(high < low);
}

test "tasks of equal priority start in the order they were queued" {
    var shell: helpers.FakeShell = undefined;
    shell.init(std.testing.allocator);
    defer shell.deinit();
    const core = try helpers.createCore(&shell, 1, 1);
    defer core.destroy();
    try addTask(core, "blocker", "sleep", "s", "{\"ms\":100,\"name\":\"blocker\"}", 0);
    try shell.expectMessageContaining("\"start\":\"blocker\"");
    try addTask(core, "one", "sleep", "s", "{\"ms\":2,\"name\":\"one\"}", 0);
    try addTask(core, "two", "sleep", "s", "{\"ms\":2,\"name\":\"two\"}", 0);
    try expectCompleted(&shell, "two", "succeeded");
    try std.testing.expect(shell.indexOfContaining("\"start\":\"one\"").? < shell.indexOfContaining("\"start\":\"two\"").?);
}

test "several tasks run at the same time up to the pool size and the rest wait their turn" {
    var shell: helpers.FakeShell = undefined;
    shell.init(std.testing.allocator);
    defer shell.deinit();
    const core = try helpers.createCore(&shell, 2, 1);
    defer core.destroy();
    try addTask(core, "t1", "sleep", "s", "{\"ms\":150,\"name\":\"t1\"}", 0);
    try addTask(core, "t2", "sleep", "s", "{\"ms\":150,\"name\":\"t2\"}", 0);
    try addTask(core, "t3", "sleep", "s", "{\"ms\":5,\"name\":\"t3\"}", 0);
    try shell.expectMessageContaining("\"start\":\"t2\"");
    shell.sleepMs(40);
    try std.testing.expectEqual(@as(usize, 0), shell.countContaining("\"start\":\"t3\""));
    try expectCompleted(&shell, "t3", "succeeded");
}

test "a duplicate task id among live tasks is refused" {
    var shell: helpers.FakeShell = undefined;
    shell.init(std.testing.allocator);
    defer shell.deinit();
    const core = try helpers.createCore(&shell, 1, 1);
    defer core.destroy();
    try addTask(core, "same", "spin", "s", "null", 0);
    core.postMessage("{\"id\":1,\"channel\":\"add-task\",\"data\":{\"taskId\":\"same\",\"taskType\":\"quick\",\"source\":\"s\",\"data\":null,\"priority\":0}}");
    try shell.expectMessageContaining("{\"id\":1,\"ok\":false,\"error\":\"DuplicateTaskId\"}");
    try cancelSource(core, "s");
    try expectCompleted(&shell, "same", "cancelled");
}

test "add-task without a task type is an error reply" {
    var shell: helpers.FakeShell = undefined;
    shell.init(std.testing.allocator);
    defer shell.deinit();
    const core = try helpers.createCore(&shell, 1, 1);
    defer core.destroy();
    core.postMessage("{\"id\":1,\"channel\":\"add-task\",\"data\":{\"taskId\":\"x\",\"source\":\"s\"}}");
    try shell.expectMessageContaining("{\"id\":1,\"ok\":false,\"error\":\"MissingTaskType\"}");
}

test "messages sent from several tasks at once all arrive, in order within each task" {
    var shell: helpers.FakeShell = undefined;
    shell.init(std.testing.allocator);
    defer shell.deinit();
    const core = try helpers.createCore(&shell, 4, 1);
    defer core.destroy();
    const count = 300;
    try addTask(core, "f1", "flooder", "s", "{\"count\":300}", 0);
    try addTask(core, "f2", "flooder", "s", "{\"count\":300}", 0);
    try addTask(core, "f3", "flooder", "s", "{\"count\":300}", 0);
    try addTask(core, "f4", "flooder", "s", "{\"count\":300}", 0);
    try expectCompleted(&shell, "f1", "succeeded");
    try expectCompleted(&shell, "f2", "succeeded");
    try expectCompleted(&shell, "f3", "succeeded");
    try expectCompleted(&shell, "f4", "succeeded");
    for ([_][]const u8{ "f1", "f2", "f3", "f4" }) |id| {
        var previous: i64 = -1;
        var seen: usize = 0;
        var index: usize = 0;
        while (index < shell.count()) : (index += 1) {
            const message = try shell.messageAt(std.testing.allocator, index);
            defer std.testing.allocator.free(message);
            var marker_buffer: [64]u8 = undefined;
            const marker = try std.fmt.bufPrint(&marker_buffer, "\"taskId\":\"{s}\",", .{id});
            if (std.mem.indexOf(u8, message, marker) == null or std.mem.indexOf(u8, message, "\"seq\":") == null) {
                continue;
            }
            const seq_start = std.mem.indexOf(u8, message, "\"seq\":").? + 6;
            const seq_end = std.mem.indexOfScalarPos(u8, message, seq_start, '}').?;
            const sequence = try std.fmt.parseInt(i64, message[seq_start..seq_end], 10);
            try std.testing.expect(sequence == previous + 1);
            previous = sequence;
            seen += 1;
        }
        try std.testing.expectEqual(@as(usize, count), seen);
    }
}

test "destroy with tasks still running cancels them, waits and leaves no leak" {
    var shell: helpers.FakeShell = undefined;
    shell.init(std.testing.allocator);
    defer shell.deinit();
    const core = try helpers.createCore(&shell, 2, 2);
    try addTask(core, "t1", "spin", "s", "null", 0);
    try addTask(core, "t2", "spin", "s", "null", 0);
    try addTask(core, "t3", "sleep", "s", "{\"ms\":100000,\"name\":\"queued\"}", 0);
    try shell.expectMessageContaining("\"taskId\":\"t2\",\"source\":\"s\",\"message\":{\"step\":1}");
    core.destroy();
}

test "a parent that queues children waits for all of them" {
    var shell: helpers.FakeShell = undefined;
    shell.init(std.testing.allocator);
    defer shell.deinit();
    const core = try helpers.createCore(&shell, 3, 4);
    defer core.destroy();
    try addTask(core, "p", "parent", "s", "{\"children\":6,\"childMs\":10,\"name\":\"p\"}", 0);
    try expectCompleted(&shell, "p", "succeeded");
    try std.testing.expectEqual(@as(usize, 6), shell.countContaining("\"childEnd\":\"p\""));
    try std.testing.expect(shell.indexOfContaining("\"allChildrenDone\":\"p\"").? > shell.indexOfContaining("\"childEnd\":\"p\"").?);
    // Each child completes on its own and carries the parent's source.
    try shell.expectMessageContaining("\"taskId\":\"p.c5\",\"source\":\"s\",\"status\":\"succeeded\"");
}

test "a parent with no children completes normally" {
    var shell: helpers.FakeShell = undefined;
    shell.init(std.testing.allocator);
    defer shell.deinit();
    const core = try helpers.createCore(&shell, 1, 1);
    defer core.destroy();
    try addTask(core, "p", "parent", "s", "{\"children\":0,\"name\":\"p\"}", 0);
    try expectCompleted(&shell, "p", "succeeded");
}

test "awaitTask returns the result of one child and a failed child is returned as a failure" {
    var shell: helpers.FakeShell = undefined;
    shell.init(std.testing.allocator);
    defer shell.deinit();
    const core = try helpers.createCore(&shell, 2, 2);
    defer core.destroy();
    try addTask(core, "p", "await-one", "s", "null", 0);
    try shell.expectMessageContaining("\"first\":\"succeeded\",\"firstResult\":\"child answer\",\"second\":\"failed\",\"secondError\":\"TestFailure\"");
}

test "no more than the child task limit run at once" {
    var shell: helpers.FakeShell = undefined;
    shell.init(std.testing.allocator);
    defer shell.deinit();
    const core = try helpers.createCore(&shell, 6, 2);
    defer core.destroy();
    try addTask(core, "p", "parent", "s", "{\"children\":8,\"childMs\":20,\"name\":\"p\"}", 0);
    try expectCompleted(&shell, "p", "succeeded");
    var running: i32 = 0;
    var most: i32 = 0;
    var index: usize = 0;
    while (index < shell.count()) : (index += 1) {
        const message = try shell.messageAt(std.testing.allocator, index);
        defer std.testing.allocator.free(message);
        if (std.mem.indexOf(u8, message, "\"childStart\"") != null) {
            running += 1;
            most = @max(most, running);
        }
        else if (std.mem.indexOf(u8, message, "\"childEnd\"") != null) {
            running -= 1;
        }
    }
    try std.testing.expect(most <= 2);
    try std.testing.expect(most >= 1);
}

test "a parent that queues more children than the pool has workers does not deadlock when every worker holds a parent" {
    var shell: helpers.FakeShell = undefined;
    shell.init(std.testing.allocator);
    defer shell.deinit();
    const core = try helpers.createCore(&shell, 2, 10);
    defer core.destroy();
    try addTask(core, "p1", "parent", "s", "{\"children\":5,\"childMs\":5,\"name\":\"p1\"}", 0);
    try addTask(core, "p2", "parent", "s", "{\"children\":5,\"childMs\":5,\"name\":\"p2\"}", 0);
    try expectCompleted(&shell, "p1", "succeeded");
    try expectCompleted(&shell, "p2", "succeeded");
    try std.testing.expectEqual(@as(usize, 5), shell.countContaining("\"childEnd\":\"p1\""));
    try std.testing.expectEqual(@as(usize, 5), shell.countContaining("\"childEnd\":\"p2\""));
}

test "children of two parents do not run more at once than the pool has workers" {
    var shell: helpers.FakeShell = undefined;
    shell.init(std.testing.allocator);
    defer shell.deinit();
    const core = try helpers.createCore(&shell, 3, 10);
    defer core.destroy();
    try addTask(core, "p1", "parent", "s", "{\"children\":6,\"childMs\":20,\"name\":\"p1\"}", 0);
    try addTask(core, "p2", "parent", "s", "{\"children\":6,\"childMs\":20,\"name\":\"p2\"}", 0);
    try expectCompleted(&shell, "p1", "succeeded");
    try expectCompleted(&shell, "p2", "succeeded");
    var running: i32 = 0;
    var most: i32 = 0;
    var index: usize = 0;
    while (index < shell.count()) : (index += 1) {
        const message = try shell.messageAt(std.testing.allocator, index);
        defer std.testing.allocator.free(message);
        if (std.mem.indexOf(u8, message, "\"childStart\"") != null) {
            running += 1;
            most = @max(most, running);
        }
        else if (std.mem.indexOf(u8, message, "\"childEnd\"") != null) {
            running -= 1;
        }
    }
    // Two parents hold two of the three threads while they wait, helping run children, so at most three tasks run.
    try std.testing.expect(most <= 3);
}

test "cancelling the parent's source cancels its children and the parent completes as cancelled" {
    var shell: helpers.FakeShell = undefined;
    shell.init(std.testing.allocator);
    defer shell.deinit();
    const core = try helpers.createCore(&shell, 3, 2);
    defer core.destroy();
    try addTask(core, "p", "blocked-parent", "s", "null", 0);
    try shell.expectMessageContaining("\"childStart\":\"blocked\"");
    try cancelSource(core, "s");
    try expectCompleted(&shell, "p", "cancelled");
    try expectCompleted(&shell, "p.c0", "cancelled");
    try expectCompleted(&shell, "p.c1", "cancelled");
}

//
// Waits until the shell has been told the given number of keep-alive changes, and returns what it was told.
//
fn keepAliveCalls(shell: *helpers.FakeShell, count: usize) ![]bool {
    var waited: u32 = 0;
    while (waited < 2000) : (waited += 1) {
        shell.mutex.lockUncancelable(shell.threaded.io());
        const have = shell.keep_alive_calls.items.len;
        shell.mutex.unlock(shell.threaded.io());
        if (have >= count) {
            break;
        }
        try std.Io.sleep(shell.threaded.io(), .fromMilliseconds(1), .awake);
    }
    shell.mutex.lockUncancelable(shell.threaded.io());
    defer shell.mutex.unlock(shell.threaded.io());
    return try std.testing.allocator.dupe(bool, shell.keep_alive_calls.items);
}

test "a keep-alive task asks the shell to keep the app running while it is queued or running, and to stop when it ends" {
    var shell: helpers.FakeShell = undefined;
    shell.init(std.testing.allocator);
    defer shell.deinit();
    const core = try helpers.createCore(&shell, 2, 2);
    defer core.destroy();
    try addTask(core, "k1", "keep-sleep", "s", "{\"ms\":30}", 0);
    const during = try keepAliveCalls(&shell, 1);
    defer std.testing.allocator.free(during);
    try std.testing.expectEqualSlices(bool, &[_]bool{true}, during[0..1]);
    try expectCompleted(&shell, "k1", "succeeded");
    const after = try keepAliveCalls(&shell, 2);
    defer std.testing.allocator.free(after);
    try std.testing.expectEqualSlices(bool, &[_]bool{ true, false }, after);
}

test "several keep-alive tasks ask once, and the shell is told to stop only when the last one ends" {
    var shell: helpers.FakeShell = undefined;
    shell.init(std.testing.allocator);
    defer shell.deinit();
    const core = try helpers.createCore(&shell, 3, 2);
    defer core.destroy();
    try addTask(core, "k1", "keep-sleep", "s1", "{\"ms\":20}", 0);
    try addTask(core, "k2", "keep-sleep", "s2", "{\"ms\":100000}", 0);
    try expectCompleted(&shell, "k1", "succeeded");
    const calls = try keepAliveCalls(&shell, 1);
    defer std.testing.allocator.free(calls);
    try std.testing.expectEqualSlices(bool, &[_]bool{true}, calls);
    try cancelSource(core, "s2");
    try expectCompleted(&shell, "k2", "cancelled");
    const done = try keepAliveCalls(&shell, 2);
    defer std.testing.allocator.free(done);
    try std.testing.expectEqualSlices(bool, &[_]bool{ true, false }, done);
}

test "a normal task never asks the shell to keep the app running" {
    var shell: helpers.FakeShell = undefined;
    shell.init(std.testing.allocator);
    defer shell.deinit();
    const core = try helpers.createCore(&shell, 2, 2);
    defer core.destroy();
    try addTask(core, "n1", "sleep", "s", "{\"ms\":10}", 0);
    try expectCompleted(&shell, "n1", "succeeded");
    try std.Io.sleep(shell.threaded.io(), .fromMilliseconds(50), .awake);
    const calls = try keepAliveCalls(&shell, 0);
    defer std.testing.allocator.free(calls);
    try std.testing.expectEqual(@as(usize, 0), calls.len);
}

test "a keep-alive parent keeps the app running until its children are done and it ends" {
    var shell: helpers.FakeShell = undefined;
    shell.init(std.testing.allocator);
    defer shell.deinit();
    const core = try helpers.createCore(&shell, 3, 2);
    defer core.destroy();
    try addTask(core, "p1", "keep-parent", "s", "{\"children\":2,\"childMs\":20}", 0);
    try expectCompleted(&shell, "p1", "succeeded");
    const calls = try keepAliveCalls(&shell, 2);
    defer std.testing.allocator.free(calls);
    try std.testing.expectEqualSlices(bool, &[_]bool{ true, false }, calls);
}

fn hostRequestTask(context: *ziggy.task_runner.TaskContext, data: std.json.Value) anyerror!?[]const u8 {
    const method = ziggy.json_util.getString(data, "method").?;
    const reply = try context.hostRequest(method, "{\"key\":\"value\"}");
    if (!reply.succeeded) {
        return try std.fmt.allocPrint(context.arena, "{{\"failedBecause\":\"{s}\"}}", .{reply.text});
    }
    return try context.arena.dupe(u8, reply.text);
}

test "a task asks the shell to do something only the platform can do, and gets its answer" {
    var shell: helpers.FakeShell = undefined;
    shell.init(std.testing.allocator);
    defer shell.deinit();
    const host_tasks = helpers.task_handlers ++ [_]ziggy.task_runner.TaskHandlerEntry{
        .{ .name = "host-request", .handler = hostRequestTask },
    };
    var host_app = helpers.app;
    host_app.tasks = &host_tasks;
    const core = try ziggy.core.Core.create(std.testing.allocator, shell.config(1, 1), host_app);
    defer core.destroy();
    core.postMessage("{\"channel\":\"add-task\",\"data\":{\"taskId\":\"h1\",\"taskType\":\"host-request\",\"source\":\"src\",\"data\":{\"method\":\"exportFile\"},\"priority\":0}}");
    try shell.expectMessageContaining("\"result\":{\"method\":\"exportFile\",\"request\":{\"key\":\"value\"}}");
}

test "a task is told why the shell could not do what was asked" {
    var shell: helpers.FakeShell = undefined;
    shell.init(std.testing.allocator);
    defer shell.deinit();
    const host_tasks = helpers.task_handlers ++ [_]ziggy.task_runner.TaskHandlerEntry{
        .{ .name = "host-request", .handler = hostRequestTask },
    };
    var host_app = helpers.app;
    host_app.tasks = &host_tasks;
    const core = try ziggy.core.Core.create(std.testing.allocator, shell.config(1, 1), host_app);
    defer core.destroy();
    core.postMessage("{\"channel\":\"add-task\",\"data\":{\"taskId\":\"h2\",\"taskType\":\"host-request\",\"source\":\"src\",\"data\":{\"method\":\"fail\"},\"priority\":0}}");
    try shell.expectMessageContaining("\"result\":{\"failedBecause\":\"The phone said no.\"}");
}

test "a task on a platform with no host request callback gets HostCallbackMissing" {
    var shell: helpers.FakeShell = undefined;
    shell.init(std.testing.allocator);
    defer shell.deinit();
    const host_tasks = helpers.task_handlers ++ [_]ziggy.task_runner.TaskHandlerEntry{
        .{ .name = "host-request", .handler = hostRequestTask },
    };
    var host_app = helpers.app;
    host_app.tasks = &host_tasks;
    var config = shell.config(1, 1);
    config.host_request = null;
    const core = try ziggy.core.Core.create(std.testing.allocator, config, host_app);
    defer core.destroy();
    core.postMessage("{\"channel\":\"add-task\",\"data\":{\"taskId\":\"h3\",\"taskType\":\"host-request\",\"source\":\"src\",\"data\":{\"method\":\"exportFile\"},\"priority\":0}}");
    try shell.expectMessageContaining("HostCallbackMissing");
}
