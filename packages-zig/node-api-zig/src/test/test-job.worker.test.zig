const std = @import("std");
const test_timers = @import("test-timers.zig");
const utils = @import("utils-zig");
const node_api = @import("node-api-zig");
const test_environment = @import("test-environment.zig");
const mock_log = @import("mock-log.zig");
const recording_task_context = @import("recording-task-context.zig");
const virtual_time_io = @import("../../../utils-zig/src/test/virtual-time-io.zig");
const errors = utils.errors;
const ITimestampProvider = utils.timestamp_provider.ITimestampProvider;
const Date = utils.timestamp_provider.Date;
const describeTestJobProgress = node_api.test_job_worker.describeTestJobProgress;
const testJobHandler = node_api.test_job_worker.testJobHandler;
const ITestJobResult = node_api.test_job_worker.ITestJobResult;
const RecordingTaskContext = recording_task_context.RecordingTaskContext;

//
// The stages of the jobs under test.
//
const STAGES = [_][]const u8{ "Scanning folders", "Reading metadata", "Building index" };

//
// A clock the test drives: each reading moves it forward by 100 milliseconds, so a job that claims to run for a minute is
// over in a moment.
//
const SteppingClock = struct {
    // The time of the last reading, in milliseconds.
    clock: i64 = 1000,

    //
    // Gets the ITimestampProvider interface for this clock.
    //
    fn timestampProvider(self: *SteppingClock) ITimestampProvider {
        return .{
            .ptr = self,
            .vtable = &vtable,
        };
    }

    //
    // The ITimestampProvider functions of this clock.
    //
    const vtable: ITimestampProvider.VTable = .{
        .now = nowErased,
        .dateNow = dateNowErased,
    };

    //
    // Moves the clock forward and reads it.
    //
    fn nowErased(ptr: *anyopaque, io: std.Io) i64 {
        _ = io;
        const self: *SteppingClock = @ptrCast(@alignCast(ptr));
        self.clock += 100;
        return self.clock;
    }

    //
    // Reads the clock as a Date, without moving it.
    //
    fn dateNowErased(ptr: *anyopaque, io: std.Io) Date {
        _ = io;
        const self: *SteppingClock = @ptrCast(@alignCast(ptr));
        return .{
            .epochMilliseconds = self.clock,
        };
    }
};

//
// Builds the task data of a job. The job tag is left out when jobId is null.
//
fn makeData(allocator: std.mem.Allocator, durationMs: i64, jobId: ?[]const u8) !std.json.Value {
    var object: std.json.ObjectMap = .empty;
    try object.put(allocator, "durationMs", .{ .integer = durationMs });
    var stages: std.json.Array = .init(allocator);
    for (STAGES) |stage| {
        try stages.append(.{ .string = stage });
    }
    try object.put(allocator, "stages", .{ .array = stages });
    try object.put(allocator, "itemCount", .{ .integer = 300 });
    if (jobId) |id| {
        var job: std.json.ObjectMap = .empty;
        try job.put(allocator, "id", .{ .string = id });
        try job.put(allocator, "name", .{ .string = "Indexing photos" });
        try job.put(allocator, "cancelSource", .{ .string = id });
        try object.put(allocator, "job", .{ .object = job });
    }
    return .{ .object = object };
}

test "describeTestJobProgress names the stage the job has reached" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    try std.testing.expect(std.mem.indexOf(u8, try describeTestJobProgress(allocator, &STAGES, 300, 0), "Scanning folders") != null);
    try std.testing.expect(std.mem.indexOf(u8, try describeTestJobProgress(allocator, &STAGES, 300, 0.5), "Reading metadata") != null);
    try std.testing.expect(std.mem.indexOf(u8, try describeTestJobProgress(allocator, &STAGES, 300, 0.9), "Building index") != null);
}

test "describeTestJobProgress counts up as the job goes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    try std.testing.expectEqualStrings("Scanning folders: 1 of 300", try describeTestJobProgress(allocator, &STAGES, 300, 0));
    try std.testing.expectEqualStrings("Reading metadata: 151 of 300", try describeTestJobProgress(allocator, &STAGES, 300, 0.5));
}

test "describeTestJobProgress never runs past the last stage or the last item" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    try std.testing.expectEqualStrings("Building index: 300 of 300", try describeTestJobProgress(allocator, &STAGES, 300, 1));
    try std.testing.expectEqualStrings("Building index: 300 of 300", try describeTestJobProgress(allocator, &STAGES, 300, 5));
}

test "describeTestJobProgress never runs before the first stage or the first item" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    try std.testing.expectEqualStrings("Scanning folders: 1 of 300", try describeTestJobProgress(allocator, &STAGES, 300, -2));
}

test "describeTestJobProgress writes undefined for the stage of a job with no stages" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    try std.testing.expectEqualStrings("undefined: 1 of 300", try describeTestJobProgress(allocator, &.{}, 300, 0));
}

test "testJobHandler stops early when cancelled, and says so" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var virtualTime: virtual_time_io.VirtualTimeIo = undefined;
    virtualTime.init(std.testing.allocator);
    defer virtualTime.deinit();
    const io = virtualTime.io();
    const test_env = try test_environment.setupEnvironment(std.testing.io);
    defer test_env.deinit();
    var mutedLog: mock_log.MutedLog = .{};
    mutedLog.install();
    defer mutedLog.uninstall();
    var clock: SteppingClock = .{};
    var context: RecordingTaskContext = undefined;
    try context.init(allocator, 0, clock.timestampProvider());

    const output = try testJobHandler(allocator, io, test_timers.timers(), try makeData(allocator, 60_000, "job-1"), context.taskContext());

    const result = try std.json.parseFromValueLeaky(ITestJobResult, allocator, output, .{});
    try std.testing.expect(result.cancelled);
    try std.testing.expectEqual(@as(i64, 100), result.elapsedMs);
}

test "testJobHandler reports its job as it runs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var virtualTime: virtual_time_io.VirtualTimeIo = undefined;
    virtualTime.init(std.testing.allocator);
    defer virtualTime.deinit();
    const io = virtualTime.io();
    const test_env = try test_environment.setupEnvironment(std.testing.io);
    defer test_env.deinit();
    var mutedLog: mock_log.MutedLog = .{};
    mutedLog.install();
    defer mutedLog.uninstall();
    var clock: SteppingClock = .{};
    var context: RecordingTaskContext = undefined;
    try context.init(allocator, 100, clock.timestampProvider());

    const output = try testJobHandler(allocator, io, test_timers.timers(), try makeData(allocator, 300, "job-1"), context.taskContext());

    const jobMessages = try context.messagesOfType("job-progress");
    try std.testing.expect(jobMessages.len > 0);
    try std.testing.expectEqualStrings("Indexing photos", jobMessages[0].object.get("job").?.object.get("name").?.string);
    try std.testing.expectEqualStrings("job-1", jobMessages[0].object.get("job").?.object.get("id").?.string);
    try std.testing.expectEqualStrings("job-1", jobMessages[0].object.get("job").?.object.get("cancelSource").?.string);

    // The clock reads 1100 at the start and 1200 and 1300 in the two passes that report progress, then 1400 which ends the job.
    try std.testing.expectEqual(@as(usize, 2), jobMessages.len);
    try std.testing.expectEqual(@as(i64, 1100), jobMessages[0].object.get("startedAt").?.integer);
    try std.testing.expectEqualStrings("Reading metadata: 101 of 300", jobMessages[0].object.get("progressMessage").?.string);
    try std.testing.expectEqualStrings("Building index: 201 of 300", jobMessages[1].object.get("progressMessage").?.string);

    const result = try std.json.parseFromValueLeaky(ITestJobResult, allocator, output, .{});
    try std.testing.expect(!result.cancelled);
    try std.testing.expectEqual(@as(i64, 400), result.elapsedMs);
}

test "testJobHandler reports no job when queued without a tag" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var virtualTime: virtual_time_io.VirtualTimeIo = undefined;
    virtualTime.init(std.testing.allocator);
    defer virtualTime.deinit();
    const io = virtualTime.io();
    const test_env = try test_environment.setupEnvironment(std.testing.io);
    defer test_env.deinit();
    var mutedLog: mock_log.MutedLog = .{};
    mutedLog.install();
    defer mutedLog.uninstall();
    var clock: SteppingClock = .{};
    var context: RecordingTaskContext = undefined;
    try context.init(allocator, 100, clock.timestampProvider());

    _ = try testJobHandler(allocator, io, test_timers.timers(), try makeData(allocator, 300, null), context.taskContext());

    const jobMessages = try context.messagesOfType("job-progress");
    try std.testing.expectEqual(@as(usize, 0), jobMessages.len);
}

test "testJobHandler finishes at once when the duration is zero" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var virtualTime: virtual_time_io.VirtualTimeIo = undefined;
    virtualTime.init(std.testing.allocator);
    defer virtualTime.deinit();
    const io = virtualTime.io();
    const test_env = try test_environment.setupEnvironment(std.testing.io);
    defer test_env.deinit();
    var mutedLog: mock_log.MutedLog = .{};
    mutedLog.install();
    defer mutedLog.uninstall();
    var clock: SteppingClock = .{};
    var context: RecordingTaskContext = undefined;
    try context.init(allocator, null, clock.timestampProvider());

    const output = try testJobHandler(allocator, io, test_timers.timers(), try makeData(allocator, 0, "job-1"), context.taskContext());

    const result = try std.json.parseFromValueLeaky(ITestJobResult, allocator, output, .{});
    try std.testing.expect(!result.cancelled);
    try std.testing.expectEqual(@as(i64, 200), result.elapsedMs);
    try std.testing.expectEqual(@as(usize, 0), context.messages.items.len);
}

test "testJobHandler throws a descriptive error when the task data is not valid" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const test_env = try test_environment.setupEnvironment(std.testing.io);
    defer test_env.deinit();
    var context: RecordingTaskContext = undefined;
    try context.init(allocator, null, null);
    var object: std.json.ObjectMap = .empty;
    try object.put(allocator, "durationMs", .{ .string = "soon" });

    try std.testing.expectError(error.Thrown, testJobHandler(allocator, std.testing.io, test_timers.timers(), .{ .object = object }, context.taskContext()));
    try std.testing.expectEqualStrings("The test-job task data is not valid: durationMs and itemCount must be whole numbers, stages must be an array of strings and job must be an object", errors.lastErrorMessage());
}
