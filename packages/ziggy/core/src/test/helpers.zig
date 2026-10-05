//
// What the core's tests share: the shell stand-in, and small task handlers.
//

const std = @import("std");
const ziggy = @import("ziggy-core");

const core_module = ziggy.core;
const task_runner = ziggy.task_runner;

//
// A stand-in for a shell that records every message the core delivers.
//
pub const FakeShell = ziggy.fake_shell.FakeShell;

// Sleeps for a task, returning error.Cancelled early when the task is cancelled.
//
pub fn sleepOrCancel(context: *task_runner.TaskContext, milliseconds: i64) !void {
    var remaining = milliseconds;
    while (remaining > 0) : (remaining -= 1) {
        try context.checkCancelled();
        try context.io().sleep(.fromMilliseconds(1), .awake);
    }
    try context.checkCancelled();
}

fn quickTask(context: *task_runner.TaskContext, data: std.json.Value) anyerror!?[]const u8 {
    _ = data;
    try context.sendMessage(.{ .text = "hello" });
    return try context.arena.dupe(u8, "\"done\"");
}

fn spinTask(context: *task_runner.TaskContext, data: std.json.Value) anyerror!?[]const u8 {
    _ = data;
    var step: u32 = 0;
    while (true) : (step += 1) {
        try context.checkCancelled();
        try context.sendMessage(.{ .step = step });
        try context.io().sleep(.fromMilliseconds(2), .awake);
    }
}

fn failTask(context: *task_runner.TaskContext, data: std.json.Value) anyerror!?[]const u8 {
    _ = context;
    _ = data;
    return error.TestFailure;
}

fn sleepTask(context: *task_runner.TaskContext, data: std.json.Value) anyerror!?[]const u8 {
    const milliseconds = ziggy.json_util.getInteger(data, "ms") orelse 0;
    const name = ziggy.json_util.getString(data, "name") orelse "sleep";
    try context.sendMessage(.{ .start = name });
    try sleepOrCancel(context, milliseconds);
    try context.sendMessage(.{ .end = name });
    return null;
}

fn parentTask(context: *task_runner.TaskContext, data: std.json.Value) anyerror!?[]const u8 {
    const children = ziggy.json_util.getInteger(data, "children") orelse 0;
    const child_ms = ziggy.json_util.getInteger(data, "childMs") orelse 5;
    const parent_name = ziggy.json_util.getString(data, "name") orelse "parent";
    var index: i64 = 0;
    while (index < children) : (index += 1) {
        _ = try context.queueChild("child", .{ .name = parent_name, .ms = child_ms });
    }
    context.awaitAllTasks();
    try context.sendMessage(.{ .allChildrenDone = parent_name });
    return null;
}

fn awaitOneTask(context: *task_runner.TaskContext, data: std.json.Value) anyerror!?[]const u8 {
    _ = data;
    const first = try context.queueChild("child-result", .{});
    const second = try context.queueChild("fail", .{});
    const first_completion = try context.awaitTask(first);
    const second_completion = try context.awaitTask(second);
    return try std.fmt.allocPrint(context.arena, "{{\"first\":\"{s}\",\"firstResult\":{s},\"second\":\"{s}\",\"secondError\":\"{s}\"}}", .{
        @tagName(first_completion.status),
        first_completion.result_json orelse "null",
        @tagName(second_completion.status),
        second_completion.error_message orelse "",
    });
}

fn childResultTask(context: *task_runner.TaskContext, data: std.json.Value) anyerror!?[]const u8 {
    _ = data;
    return try context.arena.dupe(u8, "\"child answer\"");
}

fn childTask(context: *task_runner.TaskContext, data: std.json.Value) anyerror!?[]const u8 {
    const milliseconds = ziggy.json_util.getInteger(data, "ms") orelse 0;
    const name = ziggy.json_util.getString(data, "name") orelse "child";
    try context.sendMessage(.{ .childStart = name });
    try sleepOrCancel(context, milliseconds);
    try context.sendMessage(.{ .childEnd = name });
    return null;
}

fn blockedParentTask(context: *task_runner.TaskContext, data: std.json.Value) anyerror!?[]const u8 {
    _ = data;
    _ = try context.queueChild("child", .{ .name = "blocked", .ms = 100000 });
    _ = try context.queueChild("child", .{ .name = "blocked", .ms = 100000 });
    context.awaitAllTasks();
    try context.checkCancelled();
    return null;
}

fn flooderTask(context: *task_runner.TaskContext, data: std.json.Value) anyerror!?[]const u8 {
    const count = ziggy.json_util.getInteger(data, "count") orelse 0;
    var index: i64 = 0;
    while (index < count) : (index += 1) {
        try context.sendMessage(.{ .seq = index });
    }
    return null;
}

//
// The task handlers the tests register.
//
pub const task_handlers = [_]task_runner.TaskHandlerEntry{
    .{ .name = "quick", .handler = quickTask },
    .{ .name = "spin", .handler = spinTask },
    .{ .name = "fail", .handler = failTask },
    .{ .name = "sleep", .handler = sleepTask },
    .{ .name = "parent", .handler = parentTask },
    .{ .name = "child", .handler = childTask },
    .{ .name = "child-result", .handler = childResultTask },
    .{ .name = "await-one", .handler = awaitOneTask },
    .{ .name = "blocked-parent", .handler = blockedParentTask },
    .{ .name = "flooder", .handler = flooderTask },
    .{ .name = "pick-open", .handler = pickOpenTask },
    .{ .name = "pick-save", .handler = pickSaveTask },
};
fn pickOpenTask(context: *task_runner.TaskContext, data: std.json.Value) anyerror!?[]const u8 {
    const title: ?[]const u8 = if (data == .string) data.string else null;
    return try context.pickPaths(.open_files, title, null);
}

fn pickSaveTask(context: *task_runner.TaskContext, data: std.json.Value) anyerror!?[]const u8 {
    const initial_name: ?[]const u8 = if (data == .string) data.string else null;
    return try context.pickPaths(.save_file, null, initial_name);
}


fn echoChannel(core: *core_module.Core, arena: std.mem.Allocator, data: std.json.Value) anyerror![]const u8 {
    _ = core;
    return try ziggy.json_util.stringify(arena, data);
}

fn failChannel(core: *core_module.Core, arena: std.mem.Allocator, data: std.json.Value) anyerror![]const u8 {
    _ = core;
    _ = arena;
    _ = data;
    return error.ChannelFailed;
}

//
// The handlers the tests register: two channels and the task handlers.
//
pub const app = core_module.AppHandlers{
    .channels = &[_]core_module.ChannelEntry{
        .{ .name = "echo", .handler = echoChannel },
        .{ .name = "fail", .handler = failChannel },
    },
    .tasks = &task_handlers,
    .menu_json = "[]",
    .ui_files = &[_]ziggy.ui_files.UiFile{
        .{
            .path = "index.html",
            .content = "<html></html>",
        },
    },
    .task_channels = &[_]core_module.TaskChannelEntry{
        .{ .name = "quick-request", .task_type = "quick" },
        .{ .name = "fail-request", .task_type = "fail" },
        .{ .name = "pick-open-request", .task_type = "pick-open" },
        .{ .name = "pick-save-request", .task_type = "pick-save" },
    },
};

//
// Creates a core on the fake shell.
//
pub fn createCore(shell: *FakeShell, worker_threads: u32, max_children: u32) !*core_module.Core {
    return try core_module.Core.create(std.testing.allocator, shell.config(worker_threads, max_children), app);
}
