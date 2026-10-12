const std = @import("std");
const ziggy = @import("ziggy-core");
const example = @import("ziggy-example-core");

const FakeShell = ziggy.fake_shell.FakeShell;

fn createCore(shell: *FakeShell) !*ziggy.core.Core {
    return try ziggy.core.Core.create(std.testing.allocator, shell.config(3, 4), example.app);
}

fn addTask(core: *ziggy.core.Core, id: []const u8, task_type: []const u8, source: []const u8, data: []const u8) !void {
    const message = try ziggy.json_util.stringify(std.testing.allocator, .{
        .channel = "add-task",
        .data = .{
            .taskId = id,
            .taskType = task_type,
            .source = source,
            .data = ziggy.json_util.Raw{ .text = data },
            .priority = "background",
        },
    });
    defer std.testing.allocator.free(message);
    core.postMessage(message);
}

test "task-stats counts the tasks that ended and the messages they sent, through the observers the example gives the core" {
    var shell: FakeShell = undefined;
    shell.init(std.testing.allocator);
    defer shell.deinit();
    const core = try createCore(&shell);
    defer core.destroy();
    core.postMessage("{\"id\":1,\"channel\":\"task-stats\",\"data\":null}");
    try shell.expectMessageContaining("{\"id\":1,\"ok\":true,\"data\":{\"tasksEnded\":0,\"messagesSent\":0}}");
    try addTask(core, "s1", "hello-short", "src", "null");
    try shell.expectMessageContaining("task-completed\",\"data\":{\"taskId\":\"s1\"");
    // The observers are called after the page is told, so the counts are asked for until they arrive.
    var waited_ms: u32 = 0;
    while (shell.countContaining("\"tasksEnded\":1,\"messagesSent\":1") == 0) : (waited_ms += 10) {
        if (waited_ms > 20_000) {
            return error.CountsNeverArrived;
        }
        core.postMessage("{\"id\":2,\"channel\":\"task-stats\",\"data\":null}");
        shell.sleepMs(10);
    }
}

test "the refuse channel's error reaches the page as the sentence the example's describer gives" {
    var shell: FakeShell = undefined;
    shell.init(std.testing.allocator);
    defer shell.deinit();
    const core = try createCore(&shell);
    defer core.destroy();
    core.postMessage("{\"id\":1,\"channel\":\"refuse\",\"data\":null}");
    try shell.expectMessageContaining("{\"id\":1,\"ok\":false,\"error\":\"The example refused, as it was asked to.\"}");
}

test "an error the describer has no sentence for is replied to by name" {
    var shell: FakeShell = undefined;
    shell.init(std.testing.allocator);
    defer shell.deinit();
    const core = try createCore(&shell);
    defer core.destroy();
    core.postMessage("{\"id\":1,\"channel\":\"fail\",\"data\":null}");
    try shell.expectMessageContaining("{\"id\":1,\"ok\":false,\"error\":\"ExampleFailure\"}");
}

test "queue-from-app queues a task from the app's code, tells the page with an app-event, and the task runs" {
    var shell: FakeShell = undefined;
    shell.init(std.testing.allocator);
    defer shell.deinit();
    const core = try createCore(&shell);
    defer core.destroy();
    core.postMessage("{\"id\":1,\"channel\":\"queue-from-app\",\"data\":{\"source\":\"app-source\"}}");
    try shell.expectMessageContaining("{\"channel\":\"app-event\",\"data\":{\"queued\":\"from-app-app-source\"}}");
    try shell.expectMessageContaining("{\"id\":1,\"ok\":true,\"data\":\"from-app-app-source\"}");
    try shell.expectMessageContaining("\"taskId\":\"from-app-app-source\",\"status\":\"succeeded\"");
}

test "queue-from-app and cancel-from-app without a source are error replies" {
    var shell: FakeShell = undefined;
    shell.init(std.testing.allocator);
    defer shell.deinit();
    const core = try createCore(&shell);
    defer core.destroy();
    core.postMessage("{\"id\":1,\"channel\":\"queue-from-app\",\"data\":{}}");
    try shell.expectMessageContaining("{\"id\":1,\"ok\":false,\"error\":\"MissingSource\"}");
    core.postMessage("{\"id\":2,\"channel\":\"cancel-from-app\",\"data\":{}}");
    try shell.expectMessageContaining("{\"id\":2,\"ok\":false,\"error\":\"MissingSource\"}");
}

test "cancel-from-app cancels, from the app's code, a task the page queued" {
    var shell: FakeShell = undefined;
    shell.init(std.testing.allocator);
    defer shell.deinit();
    const core = try createCore(&shell);
    defer core.destroy();
    try addTask(core, "long", "hello-long", "to-cancel", "{\"durationMs\":60000,\"stepMs\":10}");
    try shell.expectMessageContaining("long task step 1");
    core.postMessage("{\"id\":1,\"channel\":\"cancel-from-app\",\"data\":{\"source\":\"to-cancel\"}}");
    try shell.expectMessageContaining("\"taskId\":\"long\",\"status\":\"failed\",\"error\":{\"message\":\"Cancelled\"}");
}

test "describe-self replies with the task's id, type, source and child limit, and the counts of the app's state it reaches through its context" {
    var shell: FakeShell = undefined;
    shell.init(std.testing.allocator);
    defer shell.deinit();
    const core = try createCore(&shell);
    defer core.destroy();
    try addTask(core, "d1", "describe-self", "self-source", "null");
    try shell.expectMessageContaining("\"outputs\":{\"taskId\":\"d1\",\"taskType\":\"describe-self\",\"source\":\"self-source\",\"maxConcurrentChildTasks\":4,\"stats\":{\"tasksEnded\":0,\"messagesSent\":0}}");
}

test "run-in-turn runs its children one after another and reports how each ended" {
    var shell: FakeShell = undefined;
    shell.init(std.testing.allocator);
    defer shell.deinit();
    const core = try createCore(&shell);
    defer core.destroy();
    try addTask(core, "r1", "run-in-turn", "turn-source", "{\"children\":3}");
    try shell.expectMessageContaining("\"outputs\":{\"ran\":3,\"statuses\":[\"succeeded\",\"succeeded\",\"succeeded\"]}");
}

test "run-in-turn stops starting children once it is cancelled" {
    var shell: FakeShell = undefined;
    shell.init(std.testing.allocator);
    defer shell.deinit();
    const core = try createCore(&shell);
    defer core.destroy();
    try addTask(core, "r2", "run-in-turn", "turn-cancel", "{\"children\":100000}");
    try shell.expectMessageContaining("child 1 running");
    core.postMessage("{\"channel\":\"cancel-tasks\",\"data\":\"turn-cancel\"}");
    try shell.expectMessageContaining("run-in-turn stopped after ");
    try shell.expectMessageContaining("\"taskId\":\"r2\",\"status\":\"failed\",\"error\":{\"message\":\"Cancelled\"}");
    try std.testing.expectEqual(@as(usize, 0), shell.countContaining("child 99999 running"));
}
