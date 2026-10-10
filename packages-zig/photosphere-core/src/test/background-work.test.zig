const std = @import("std");
const background_work = @import("../lib/background-work.zig");

const LoopHost = background_work.LoopHost;
const IStep = background_work.IStep;
const IStepResult = background_work.IStepResult;
const ReplicaState = background_work.ReplicaState;

//
// A host that plays back what a test scripts: the outputs of each planning task, the result of each step, and how many waits between
// passes it allows before it says the loop was stopped. It records everything the loop did, in order.
//
const ScriptedHost = struct {
    // Allocates the records.
    allocator: std.mem.Allocator,
    // The outputs each planning task gives, as JSON text, in the order they are asked for. A plan past the end is a test mistake.
    plans: []const []const u8,
    // How many plans have been given.
    plans_given: usize,
    // The result each step gives, in the order they are run.
    step_results: []const IStepResult,
    // How many steps have run.
    steps_run: usize,
    // True when readPlan fails instead of giving a plan.
    plan_fails: bool,
    // How many waits are allowed before the host says it was stopped.
    pauses_allowed: usize,
    // The lengths of the waits asked for.
    pauses: std.ArrayList(u64),
    // What the loop did, one line each: "plan <task>", "step <type>", "awake true", "awake false", "report <text>", "error <text>".
    events: std.ArrayList([]const u8),
    // The request the last plan was asked with, as JSON text.
    last_plan_request: ?[]const u8,

    const vtable: LoopHost.VTable = .{
        .readPlan = readPlan,
        .runStep = runStep,
        .pause = pause,
        .holdAwake = holdAwake,
        .report = report,
        .reportError = reportError,
        .isStopped = isStopped,
    };

    fn host(self: *ScriptedHost) LoopHost {
        return .{
            .ptr = self,
            .vtable = &vtable,
        };
    }

    fn note(self: *ScriptedHost, comptime format: []const u8, args: anytype) void {
        const line = std.fmt.allocPrint(self.allocator, format, args) catch @panic("out of memory");
        self.events.append(self.allocator, line) catch @panic("out of memory");
    }

    fn deinit(self: *ScriptedHost) void {
        for (self.events.items) |line| {
            self.allocator.free(line);
        }
        self.events.deinit(self.allocator);
        self.pauses.deinit(self.allocator);
        if (self.last_plan_request) |text| {
            self.allocator.free(text);
        }
    }

    fn readPlan(ptr: *anyopaque, allocator: std.mem.Allocator, plan_task: []const u8, data: std.json.Value) anyerror!std.json.Value {
        const self: *ScriptedHost = @ptrCast(@alignCast(ptr));
        self.note("plan {s}", .{plan_task});
        if (self.last_plan_request) |text| {
            self.allocator.free(text);
        }
        self.last_plan_request = try std.json.Stringify.valueAlloc(self.allocator, data, .{});
        if (self.plan_fails) {
            return error.PlanTaskFailed;
        }
        const text = self.plans[self.plans_given];
        self.plans_given += 1;
        return try std.json.parseFromSliceLeaky(std.json.Value, allocator, text, .{});
    }

    fn runStep(ptr: *anyopaque, allocator: std.mem.Allocator, step: IStep) anyerror!IStepResult {
        _ = allocator;
        const self: *ScriptedHost = @ptrCast(@alignCast(ptr));
        self.note("step {s}", .{step.@"type"});
        const result = self.step_results[self.steps_run];
        self.steps_run += 1;
        return result;
    }

    fn pause(ptr: *anyopaque, millis: u64) bool {
        const self: *ScriptedHost = @ptrCast(@alignCast(ptr));
        self.pauses.append(self.allocator, millis) catch @panic("out of memory");
        if (self.pauses_allowed == 0) {
            return false;
        }
        self.pauses_allowed -= 1;
        return true;
    }

    fn holdAwake(ptr: *anyopaque, awake: bool) anyerror!void {
        const self: *ScriptedHost = @ptrCast(@alignCast(ptr));
        self.note("awake {}", .{awake});
    }

    fn report(ptr: *anyopaque, message: []const u8) void {
        const self: *ScriptedHost = @ptrCast(@alignCast(ptr));
        self.note("report {s}", .{message});
    }

    fn reportError(ptr: *anyopaque, message: []const u8) void {
        const self: *ScriptedHost = @ptrCast(@alignCast(ptr));
        self.note("error {s}", .{message});
    }

    fn isStopped(ptr: *anyopaque) bool {
        _ = ptr;
        return false;
    }
};

fn newHost(plans: []const []const u8, step_results: []const IStepResult, pauses_allowed: usize) ScriptedHost {
    return .{
        .allocator = std.testing.allocator,
        .plans = plans,
        .plans_given = 0,
        .step_results = step_results,
        .steps_run = 0,
        .plan_fails = false,
        .pauses_allowed = pauses_allowed,
        .pauses = .empty,
        .events = .empty,
        .last_plan_request = null,
    };
}

fn expectEvents(host: *ScriptedHost, expected: []const []const u8) !void {
    try std.testing.expectEqual(expected.len, host.events.items.len);
    for (expected, host.events.items) |want, got| {
        try std.testing.expectEqualStrings(want, got);
    }
}

const ok: IStepResult = .{
    .succeeded = true,
    .files_fetched = 0,
    .files_still_missing = 0,
};

const failed: IStepResult = .{
    .succeeded = false,
    .files_fetched = 0,
    .files_still_missing = 0,
};

test "the import loop ends at once when the plan says automatic import is switched off" {
    var host = newHost(&.{"{\"shouldRun\":false,\"pauseBetweenRunsMs\":1000,\"steps\":[]}"}, &.{}, 5);
    defer host.deinit();
    background_work.runImportLoop(std.testing.allocator, host.host());
    try expectEvents(&host, &.{
        "plan plan-auto-import",
        "report Automatic import is switched off.",
        "report Automatic import is switched off. The sync loop carries on.",
    });
    try std.testing.expectEqual(@as(usize, 0), host.pauses.items.len);
}

test "the import loop runs the steps in order with the phone held awake, waits the gap the plan asked for, and stops when the wait is cut short" {
    const plan = "{\"shouldRun\":true,\"databasePath\":\"photos\",\"pauseBetweenRunsMs\":7000,\"steps\":[{\"type\":\"create-default-database\",\"data\":{}},{\"type\":\"import-assets\",\"data\":{\"a\":1}}]}";
    var host = newHost(&.{plan}, &.{ ok, ok }, 0);
    defer host.deinit();
    background_work.runImportLoop(std.testing.allocator, host.host());
    try expectEvents(&host, &.{
        "plan plan-auto-import",
        "awake true",
        "report Automatic import running into \"photos\".",
        "step create-default-database",
        "step import-assets",
        "awake false",
    });
    try std.testing.expectEqual(@as(usize, 1), host.pauses.items.len);
    try std.testing.expectEqual(@as(u64, 7000), host.pauses.items[0]);
}

test "the import loop keeps going after a plan it could not read, waiting the fallback gap" {
    var host = newHost(&.{}, &.{}, 0);
    host.plan_fails = true;
    defer host.deinit();
    background_work.runImportLoop(std.testing.allocator, host.host());
    try expectEvents(&host, &.{
        "plan plan-auto-import",
        "error Could not work out what automatic import should do: PlanTaskFailed",
    });
    try std.testing.expectEqual(@as(u64, background_work.FALLBACK_PAUSE_MS), host.pauses.items[0]);
}

test "the import loop abandons the rest of a pass when a step does not succeed, and tries again on the next" {
    const plan = "{\"shouldRun\":true,\"databasePath\":\"photos\",\"pauseBetweenRunsMs\":10,\"steps\":[{\"type\":\"first\",\"data\":{}},{\"type\":\"second\",\"data\":{}}]}";
    var host = newHost(&.{ plan, plan }, &.{ failed, ok, ok }, 1);
    defer host.deinit();
    background_work.runImportLoop(std.testing.allocator, host.host());
    try expectEvents(&host, &.{
        "plan plan-auto-import",
        "awake true",
        "report Automatic import running into \"photos\".",
        "step first",
        "error Automatic import step \"first\" did not succeed.",
        "awake false",
        "plan plan-auto-import",
        "awake true",
        "report Automatic import running into \"photos\".",
        "step first",
        "step second",
        "awake false",
    });
}

test "a gap of zero or less in a plan is replaced by the fallback" {
    const plan = "{\"shouldRun\":true,\"databasePath\":\"photos\",\"pauseBetweenRunsMs\":0,\"steps\":[]}";
    var host = newHost(&.{plan}, &.{}, 0);
    defer host.deinit();
    background_work.runImportLoop(std.testing.allocator, host.host());
    try std.testing.expectEqual(@as(u64, background_work.FALLBACK_PAUSE_MS), host.pauses.items[0]);
}

test "the sync loop tells the plan what the prefetch is doing, and says why it is not syncing" {
    const plan = "{\"shouldRun\":false,\"reason\":\"syncing is off\",\"pauseBetweenRunsMs\":0,\"steps\":[]}";
    var host = newHost(&.{plan}, &.{}, 0);
    defer host.deinit();
    var state: std.atomic.Value(ReplicaState) = .init(.working);
    background_work.runSyncLoop(std.testing.allocator, host.host(), &state);
    try expectEvents(&host, &.{
        "plan plan-sync",
        "report Not syncing: syncing is off",
    });
    try std.testing.expectEqualStrings("{\"prefetchState\":\"working\"}", host.last_plan_request.?);
    try std.testing.expectEqual(@as(u64, background_work.SYNC_FALLBACK_PAUSE_MS), host.pauses.items[0]);
}

test "the sync loop runs the sync step with the phone held awake" {
    const plan = "{\"shouldRun\":true,\"databasePath\":\"photos\",\"pauseBetweenRunsMs\":300,\"steps\":[{\"type\":\"sync-database\",\"data\":{}}]}";
    var host = newHost(&.{plan}, &.{ok}, 0);
    defer host.deinit();
    var state: std.atomic.Value(ReplicaState) = .init(.unknown);
    background_work.runSyncLoop(std.testing.allocator, host.host(), &state);
    try expectEvents(&host, &.{
        "plan plan-sync",
        "awake true",
        "report Syncing \"photos\".",
        "step sync-database",
        "awake false",
    });
    try std.testing.expectEqual(@as(u64, 300), host.pauses.items[0]);
}

const prefetch_plan = "{\"shouldRun\":true,\"databasePath\":\"replica\",\"pauseBetweenRunsMs\":50,\"steps\":[{\"type\":\"prefetch-database\",\"data\":{}}]}";

test "the prefetch loop ends itself, and marks the replica complete, when a pass fetches nothing and finds nothing missing" {
    var host = newHost(&.{prefetch_plan}, &.{ok}, 5);
    defer host.deinit();
    var state: std.atomic.Value(ReplicaState) = .init(.unknown);
    background_work.runPrefetchLoop(std.testing.allocator, host.host(), &state);
    try std.testing.expectEqual(ReplicaState.complete, state.load(.acquire));
    try expectEvents(&host, &.{
        "plan plan-prefetch",
        "awake true",
        "report Filling in \"replica\".",
        "step prefetch-database",
        "report \"replica\" is filled in; nothing left to fetch.",
        "awake false",
        "report The replica is filled in, so the background prefetch loop has finished. Opening a database starts it again.",
    });
    try std.testing.expectEqual(@as(usize, 0), host.pauses.items.len);
}

test "the prefetch loop is working while a pass fetches files, and stalled when it fetches nothing and files are still missing" {
    const fetched: IStepResult = .{
        .succeeded = true,
        .files_fetched = 3,
        .files_still_missing = 0,
    };
    const stuck: IStepResult = .{
        .succeeded = true,
        .files_fetched = 0,
        .files_still_missing = 2,
    };
    var host = newHost(&.{prefetch_plan}, &.{fetched}, 0);
    var state: std.atomic.Value(ReplicaState) = .init(.unknown);
    background_work.runPrefetchLoop(std.testing.allocator, host.host(), &state);
    try std.testing.expectEqual(ReplicaState.working, state.load(.acquire));
    host.deinit();

    host = newHost(&.{prefetch_plan}, &.{stuck}, 0);
    defer host.deinit();
    background_work.runPrefetchLoop(std.testing.allocator, host.host(), &state);
    try std.testing.expectEqual(ReplicaState.stalled, state.load(.acquire));
}

test "the prefetch loop is stalled and keeps going when a step does not succeed" {
    var host = newHost(&.{prefetch_plan}, &.{failed}, 0);
    defer host.deinit();
    var state: std.atomic.Value(ReplicaState) = .init(.unknown);
    background_work.runPrefetchLoop(std.testing.allocator, host.host(), &state);
    try std.testing.expectEqual(ReplicaState.stalled, state.load(.acquire));
    try std.testing.expectEqualStrings("error Prefetch step \"prefetch-database\" did not succeed.", host.events.items[host.events.items.len - 2]);
    try std.testing.expectEqual(@as(usize, 1), host.pauses.items.len);
}

test "the prefetch loop says why it is not running and keeps asking" {
    const refused = "{\"shouldRun\":false,\"reason\":\"a prefetch is still filling this database in\",\"pauseBetweenRunsMs\":50,\"steps\":[]}";
    var host = newHost(&.{refused}, &.{}, 0);
    defer host.deinit();
    var state: std.atomic.Value(ReplicaState) = .init(.unknown);
    background_work.runPrefetchLoop(std.testing.allocator, host.host(), &state);
    try expectEvents(&host, &.{
        "plan plan-prefetch",
        "report No database to fill in: a prefetch is still filling this database in",
    });
    try std.testing.expectEqual(ReplicaState.unknown, state.load(.acquire));
}

test "a plan whose step has no type is an error, and a plan that is not an object is too" {
    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const no_type = try std.json.parseFromSliceLeaky(std.json.Value, arena, "{\"steps\":[{\"data\":{}}]}", .{});
    try std.testing.expectError(error.Thrown, background_work.parsePlan(arena, no_type, 5));
    const no_data = try std.json.parseFromSliceLeaky(std.json.Value, arena, "{\"steps\":[{\"type\":\"x\"}]}", .{});
    try std.testing.expectError(error.Thrown, background_work.parsePlan(arena, no_data, 5));
    try std.testing.expectError(error.Thrown, background_work.parsePlan(arena, .null, 5));
}

test "a plan that says nothing refuses the pass and takes the fallback gap" {
    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const empty = try std.json.parseFromSliceLeaky(std.json.Value, arena, "{}", .{});
    const plan = try background_work.parsePlan(arena, empty, 42);
    try std.testing.expect(!plan.should_run);
    try std.testing.expectEqual(@as(u64, 42), plan.pause_ms);
    try std.testing.expectEqual(@as(usize, 0), plan.steps.len);
}

test "the counts of a prefetch step are read from its outputs, and a step with none fetched nothing" {
    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const counts = background_work.readPrefetchStepCounts(try std.json.parseFromSliceLeaky(std.json.Value, arena, "{\"filesFetched\":4,\"filesStillMissing\":1}", .{}));
    try std.testing.expectEqual(@as(u64, 4), counts.files_fetched);
    try std.testing.expectEqual(@as(u64, 1), counts.files_still_missing);
    const nothing = background_work.readPrefetchStepCounts(null);
    try std.testing.expect(nothing.succeeded);
    try std.testing.expectEqual(@as(u64, 0), nothing.files_fetched);
    try std.testing.expectEqual(@as(u64, 0), nothing.files_still_missing);
}

test "a task type is matched to its loop" {
    try std.testing.expectEqual(background_work.Loop.import, background_work.Loop.fromTaskType("background-auto-import").?);
    try std.testing.expectEqual(background_work.Loop.sync, background_work.Loop.fromTaskType("background-sync").?);
    try std.testing.expectEqual(background_work.Loop.prefetch, background_work.Loop.fromTaskType("background-prefetch").?);
    try std.testing.expect(background_work.Loop.fromTaskType("sync-database") == null);
}
