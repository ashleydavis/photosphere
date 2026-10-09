const std = @import("std");
const utils = @import("utils-zig");
const support = @import("test-support.zig");

const TestApp = support.TestApp;

//
// Queues a task of a type ported from the TypeScript workers, with the add-task message the page sends.
//
fn addTask(app: *TestApp, task_id: []const u8, task_type: []const u8, data_json: []const u8) !void {
    const message = try utils.json.stringify(std.testing.allocator, .{
        .channel = "add-task",
        .data = .{
            .taskId = task_id,
            .taskType = task_type,
            .source = "registered",
            .data = utils.json.Raw{ .text = data_json },
            .priority = "background",
        },
    });
    defer std.testing.allocator.free(message);
    app.core.postMessage(message);
}

test "a task type ported from the TypeScript workers runs on Ziggy's runner and its outputs reach the page" {
    var app: TestApp = undefined;
    try app.start();
    defer app.stop();
    const missing = try std.fmt.allocPrint(std.testing.allocator, "{s}/no-database-here", .{app.tmp_path});
    defer std.testing.allocator.free(missing);
    const data = try utils.json.stringify(std.testing.allocator, .{
        .databasePath = missing,
    });
    defer std.testing.allocator.free(data);
    try addTask(&app, "exists-1", "check-database-exists", data);
    try app.shell.expectMessageContaining("\"taskId\":\"exists-1\",\"status\":\"succeeded\",\"outputs\":{\"exists\":false},\"type\":\"check-database-exists\"");
}

test "a ported task type that throws gives the page the message it threw" {
    var app: TestApp = undefined;
    try app.start();
    defer app.stop();
    try addTask(&app, "exists-2", "check-database-exists", "{}");
    try app.shell.expectMessageContaining("\"taskId\":\"exists-2\",\"status\":\"failed\",\"error\":{\"message\":\"databasePath is required\"},\"errorMessage\":\"databasePath is required\"");
}

test "a task type nothing is registered for still fails as an unknown type" {
    var app: TestApp = undefined;
    try app.start();
    defer app.stop();
    try addTask(&app, "nothing-1", "no-such-task-type", "null");
    try app.shell.expectMessageContaining("\"taskId\":\"nothing-1\",\"status\":\"failed\",\"error\":{\"message\":\"UnknownTaskType\"}");
}
