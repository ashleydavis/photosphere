//
// The example's task types. They are an ordinary part of the example, kept permanently to show how a task is written.
//

const std = @import("std");
const ziggy = @import("ziggy-core");

const TaskContext = ziggy.task_runner.TaskContext;
const json_util = ziggy.json_util;

//
// How the example names a job in its job-progress messages, read from the "job" field of a task's data.
//
const JobTag = struct {
    // The job's id. Tasks sharing an id are one job.
    id: []const u8,
    // The job's name.
    name: []const u8,
    // The source whose cancellation cancels the job, when it has one.
    cancelSource: ?[]const u8,
};

//
// Reads the job tag from a task's data, or null when the task is not part of a job.
//
fn readJobTag(data: std.json.Value) ?JobTag {
    if (data != .object) {
        return null;
    }
    const job = data.object.get("job") orelse {
        return null;
    };
    const id = json_util.getString(job, "id") orelse {
        return null;
    };
    const name = json_util.getString(job, "name") orelse {
        return null;
    };
    return .{
        .id = id,
        .name = name,
        .cancelSource = json_util.getString(job, "cancelSource"),
    };
}

//
// Sends a job-progress message, which has the fields of IJobProgressMessage, and does nothing when the task has no job.
//
fn sendJobProgress(context: *TaskContext, job: ?JobTag, started_at: i64, progress_message: []const u8) !void {
    const tag = job orelse {
        return;
    };
    try context.sendMessage(.{
        .type = "job-progress",
        .job = tag,
        .startedAt = started_at,
        .progressMessage = progress_message,
    });
}

//
// Sends an output message, whose text the page shows in its output area.
//
fn sendOutput(context: *TaskContext, text: []const u8) !void {
    try context.sendMessage(.{
        .type = "output",
        .text = text,
    });
}

fn nowMilliseconds(context: *TaskContext) i64 {
    return std.Io.Clock.real.now(context.io()).toMilliseconds();
}

//
// Does a small amount of work: an output message, a job-progress message, then done.
//
pub fn helloShortHandler(context: *TaskContext, data: std.json.Value) anyerror!?[]const u8 {
    const started_at = nowMilliseconds(context);
    try sendOutput(context, "hello from a short task");
    try sendJobProgress(context, readJobTag(data), started_at, "short task working");
    return try context.arena.dupe(u8, "\"short task done\"");
}

//
// Loops for "durationMs" in steps of "stepMs", checking for cancellation at every step and sending an output message
// and a job-progress message at every step. While it runs it queues "children" hello-child tasks, no more than the
// child limit at a time, then waits for them all and reports each one's completion in its own output.
//
pub fn helloLongHandler(context: *TaskContext, data: std.json.Value) anyerror!?[]const u8 {
    const duration_ms = json_util.getInteger(data, "durationMs") orelse 1000;
    const step_ms = json_util.getInteger(data, "stepMs") orelse 50;
    const children = json_util.getInteger(data, "children") orelse 0;
    const job = readJobTag(data);
    const started_at = nowMilliseconds(context);
    var child_ids: std.ArrayList([]const u8) = .empty;
    var elapsed: i64 = 0;
    var step: i64 = 0;
    while (elapsed < duration_ms) {
        try context.checkCancelled();
        step += 1;
        const line = try std.fmt.allocPrint(context.arena, "long task step {d}", .{step});
        try sendOutput(context, line);
        try sendJobProgress(context, job, started_at, line);
        if (@as(i64, @intCast(child_ids.items.len)) < children) {
            const child_id = try context.queueChild("hello-child", .{
                .index = child_ids.items.len,
                .job = job,
            });
            try child_ids.append(context.arena, child_id);
        }
        try context.io().sleep(.fromMilliseconds(step_ms), .awake);
        elapsed += step_ms;
    }
    // A task that is asked for more children than it had steps to start them in starts the rest now.
    while (@as(i64, @intCast(child_ids.items.len)) < children) {
        const child_id = try context.queueChild("hello-child", .{
            .index = child_ids.items.len,
            .job = job,
        });
        try child_ids.append(context.arena, child_id);
    }
    for (child_ids.items) |child_id| {
        const completion = try context.awaitTask(child_id);
        const line = try std.fmt.allocPrint(context.arena, "child {s} {s}", .{ child_id, @tagName(completion.status) });
        try sendOutput(context, line);
    }
    try context.checkCancelled();
    try sendJobProgress(context, job, started_at, "long task finished");
    return try std.fmt.allocPrint(context.arena, "{{\"steps\":{d},\"children\":{d}}}", .{ step, child_ids.items.len });
}

//
// A child of hello-long: an output message, a job-progress message under the parent's job id, a short wait, then done.
//
pub fn helloChildHandler(context: *TaskContext, data: std.json.Value) anyerror!?[]const u8 {
    const started_at = nowMilliseconds(context);
    const index = json_util.getInteger(data, "index") orelse 0;
    const line = try std.fmt.allocPrint(context.arena, "child {d} running", .{index});
    try sendOutput(context, line);
    try sendJobProgress(context, readJobTag(data), started_at, line);
    var waited: i64 = 0;
    while (waited < 100) : (waited += 10) {
        try context.checkCancelled();
        try context.io().sleep(.fromMilliseconds(10), .awake);
    }
    return try std.fmt.allocPrint(context.arena, "{{\"index\":{d}}}", .{index});
}

//
// Always fails, so the failure path is exercised.
//
pub fn helloFailHandler(context: *TaskContext, data: std.json.Value) anyerror!?[]const u8 {
    _ = context;
    _ = data;
    return error.HelloFailure;
}

//
// Asks the shell, through the native host callback, for the operating system's version and returns it.
//
pub fn osVersionHandler(context: *TaskContext, data: std.json.Value) anyerror!?[]const u8 {
    _ = data;
    const os_version = context.config().os_version orelse {
        return error.HostCallbackMissing;
    };
    const buffer = try context.arena.alloc(u8, 1024);
    const length = os_version(context.config().user_data, buffer.ptr, buffer.len);
    if (length < 0) {
        return error.HostCallbackFailed;
    }
    const text = buffer[0..@intCast(length)];
    try sendOutput(context, "asked the operating system for its version");
    return text;
}
