const std = @import("std");
const test_timers = @import("test-timers.zig");
const Timers = @import("ziggy").timers.Timers;
const background_work = @import("photosphere-core").background_work;

const PassServices = background_work.PassServices;
const IPassResult = background_work.IPassResult;
const IStep = background_work.IStep;
const IStepResult = background_work.IStepResult;
const ReplicaState = background_work.ReplicaState;

//
// Pass services that play back what a test scripts: the outputs of each planning task and the result of each step. They record
// everything the pass did, in order, and own an arena the pass allocates from.
//
const ScriptedPassServices = struct {
    // Allocates the records.
    allocator: std.mem.Allocator,
    // What the pass allocates from, freed with the pass services.
    arena: std.heap.ArenaAllocator,
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
    // What the pass did, one line each: "plan <task>", "step <type>", "awake true", "awake false", "report <text>", "error <text>".
    events: std.ArrayList([]const u8),
    // The request the last plan was asked with, as JSON text.
    last_plan_request: ?[]const u8,
    // How many steps run before the pass services report the pass as stopped, or null when it is never stopped that way.
    stop_after_steps: ?usize,

    const vtable: PassServices.VTable = .{
        .readPlan = readPlan,
        .runStep = runStep,
        .holdAwake = holdAwake,
        .report = report,
        .reportError = reportError,
        .isStopped = isStopped,
    };

    fn passServices(self: *ScriptedPassServices) PassServices {
        return .{
            .ptr = self,
            .vtable = &vtable,
        };
    }

    fn note(self: *ScriptedPassServices, comptime format: []const u8, args: anytype) void {
        const line = std.fmt.allocPrint(self.allocator, format, args) catch @panic("out of memory");
        self.events.append(self.allocator, line) catch @panic("out of memory");
    }

    fn deinit(self: *ScriptedPassServices) void {
        for (self.events.items) |line| {
            self.allocator.free(line);
        }
        self.events.deinit(self.allocator);
        if (self.last_plan_request) |text| {
            self.allocator.free(text);
        }
        self.arena.deinit();
    }

    // What the pass allocates from.
    fn passAllocator(self: *ScriptedPassServices) std.mem.Allocator {
        return self.arena.allocator();
    }

    fn readPlan(ptr: *anyopaque, _: std.Io, allocator: std.mem.Allocator, _: Timers, plan_task: []const u8, data: std.json.Value) anyerror!std.json.Value {
        const self: *ScriptedPassServices = @ptrCast(@alignCast(ptr));
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

    fn runStep(ptr: *anyopaque, _: std.Io, allocator: std.mem.Allocator, _: Timers, _: background_work.Pass, step: IStep) anyerror!IStepResult {
        _ = allocator;
        const self: *ScriptedPassServices = @ptrCast(@alignCast(ptr));
        self.note("step {s}", .{step.@"type"});
        const result = self.step_results[self.steps_run];
        self.steps_run += 1;
        return result;
    }

    fn holdAwake(ptr: *anyopaque, _: std.Io, _: std.mem.Allocator, _: Timers, awake: bool) anyerror!void {
        const self: *ScriptedPassServices = @ptrCast(@alignCast(ptr));
        self.note("awake {}", .{awake});
    }

    fn report(ptr: *anyopaque, _: std.Io, _: std.mem.Allocator, _: Timers, message: []const u8) void {
        const self: *ScriptedPassServices = @ptrCast(@alignCast(ptr));
        self.note("report {s}", .{message});
    }

    fn reportError(ptr: *anyopaque, _: std.Io, _: std.mem.Allocator, _: Timers, message: []const u8) void {
        const self: *ScriptedPassServices = @ptrCast(@alignCast(ptr));
        self.note("error {s}", .{message});
    }

    fn isStopped(ptr: *anyopaque, _: std.Io, _: std.mem.Allocator) bool {
        const self: *ScriptedPassServices = @ptrCast(@alignCast(ptr));
        const limit = self.stop_after_steps orelse {
            return false;
        };
        return self.steps_run >= limit;
    }
};

fn newPassServices(plans: []const []const u8, step_results: []const IStepResult) ScriptedPassServices {
    return .{
        .allocator = std.testing.allocator,
        .arena = std.heap.ArenaAllocator.init(std.testing.allocator),
        .plans = plans,
        .plans_given = 0,
        .step_results = step_results,
        .steps_run = 0,
        .plan_fails = false,
        .events = .empty,
        .last_plan_request = null,
        .stop_after_steps = null,
    };
}

fn expectEvents(pass_services: *ScriptedPassServices, expected: []const []const u8) !void {
    try std.testing.expectEqual(expected.len, pass_services.events.items.len);
    for (expected, pass_services.events.items) |want, got| {
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

fn expectResult(expected_gap_ms: u64, expected_finished: bool, result: IPassResult) !void {
    try std.testing.expectEqual(expected_gap_ms, result.gap_ms);
    try std.testing.expectEqual(expected_finished, result.finished);
}

test "an import pass finishes the work when the plan says automatic import is switched off" {
    var pass_services = newPassServices(&.{"{\"shouldRun\":false,\"pauseBetweenRunsMs\":1000,\"steps\":[]}"}, &.{});
    defer pass_services.deinit();
    const result = background_work.runImportPass(std.testing.io, pass_services.passAllocator(), test_timers.timers(), pass_services.passServices());
    try expectEvents(&pass_services, &.{
        "plan plan-auto-import",
        "report Automatic import is switched off.",
    });
    try expectResult(1000, true, result);
}

test "an import pass runs the steps in order with the phone held awake, and asks for the gap the plan gave" {
    const plan = "{\"shouldRun\":true,\"databasePath\":\"photos\",\"pauseBetweenRunsMs\":7000,\"steps\":[{\"type\":\"create-default-database\",\"data\":{}},{\"type\":\"import-assets\",\"data\":{\"a\":1}}]}";
    var pass_services = newPassServices(&.{plan}, &.{ ok, ok });
    defer pass_services.deinit();
    const result = background_work.runImportPass(std.testing.io, pass_services.passAllocator(), test_timers.timers(), pass_services.passServices());
    try expectEvents(&pass_services, &.{
        "plan plan-auto-import",
        "awake true",
        "report Automatic import running into \"photos\".",
        "step create-default-database",
        "step import-assets",
        "awake false",
    });
    try expectResult(7000, false, result);
}

test "an import pass whose plan could not be read does not finish the work, and asks for the fallback gap" {
    var pass_services = newPassServices(&.{}, &.{});
    pass_services.plan_fails = true;
    defer pass_services.deinit();
    const result = background_work.runImportPass(std.testing.io, pass_services.passAllocator(), test_timers.timers(), pass_services.passServices());
    try expectEvents(&pass_services, &.{
        "plan plan-auto-import",
        "error Could not work out what automatic import should do: PlanTaskFailed",
    });
    try expectResult(background_work.FALLBACK_PAUSE_MS, false, result);
}

test "an import pass abandons the rest of its steps when one does not succeed, and does not finish the work" {
    const plan = "{\"shouldRun\":true,\"databasePath\":\"photos\",\"pauseBetweenRunsMs\":10,\"steps\":[{\"type\":\"first\",\"data\":{}},{\"type\":\"second\",\"data\":{}}]}";
    var pass_services = newPassServices(&.{plan}, &.{failed});
    defer pass_services.deinit();
    const result = background_work.runImportPass(std.testing.io, pass_services.passAllocator(), test_timers.timers(), pass_services.passServices());
    try expectEvents(&pass_services, &.{
        "plan plan-auto-import",
        "awake true",
        "report Automatic import running into \"photos\".",
        "step first",
        "error Automatic import step \"first\" did not succeed.",
        "awake false",
    });
    try expectResult(10, false, result);
}

test "a gap of zero or less in a plan is replaced by the fallback" {
    const plan = "{\"shouldRun\":true,\"databasePath\":\"photos\",\"pauseBetweenRunsMs\":0,\"steps\":[]}";
    var pass_services = newPassServices(&.{plan}, &.{});
    defer pass_services.deinit();
    const result = background_work.runImportPass(std.testing.io, pass_services.passAllocator(), test_timers.timers(), pass_services.passServices());
    try expectResult(background_work.FALLBACK_PAUSE_MS, false, result);
}

test "a sync pass tells the plan what the prefetch is doing, and says why it is not syncing" {
    const plan = "{\"shouldRun\":false,\"reason\":\"syncing is off\",\"pauseBetweenRunsMs\":0,\"steps\":[]}";
    var pass_services = newPassServices(&.{plan}, &.{});
    defer pass_services.deinit();
    var state: ReplicaState = .working;
    const result = background_work.runSyncPass(std.testing.io, pass_services.passAllocator(), test_timers.timers(), pass_services.passServices(), &state, false);
    try expectEvents(&pass_services, &.{
        "plan plan-sync",
        "report Not syncing: syncing is off",
    });
    try std.testing.expectEqualStrings("{\"prefetchState\":\"working\"}", pass_services.last_plan_request.?);
    try expectResult(background_work.SYNC_FALLBACK_PAUSE_MS, false, result);
}

test "a sync pass runs the sync step with the phone held awake" {
    const plan = "{\"shouldRun\":true,\"databasePath\":\"photos\",\"pauseBetweenRunsMs\":300,\"steps\":[{\"type\":\"sync-database\",\"data\":{}}]}";
    var pass_services = newPassServices(&.{plan}, &.{ok});
    defer pass_services.deinit();
    var state: ReplicaState = .unknown;
    const result = background_work.runSyncPass(std.testing.io, pass_services.passAllocator(), test_timers.timers(), pass_services.passServices(), &state, false);
    try expectEvents(&pass_services, &.{
        "plan plan-sync",
        "awake true",
        "report Syncing \"photos\".",
        "step sync-database",
        "awake false",
    });
    try expectResult(300, false, result);
}

test "the first sync pass only reads the gap, so the first sync waits the configured pause" {
    const plan = "{\"shouldRun\":true,\"databasePath\":\"photos\",\"pauseBetweenRunsMs\":300,\"steps\":[{\"type\":\"sync-database\",\"data\":{}}]}";
    var pass_services = newPassServices(&.{plan}, &.{ok});
    defer pass_services.deinit();
    var state: ReplicaState = .unknown;
    const result = background_work.runSyncPass(std.testing.io, pass_services.passAllocator(), test_timers.timers(), pass_services.passServices(), &state, true);
    try expectEvents(&pass_services, &.{
        "plan plan-sync",
    });
    try expectResult(300, false, result);
}

const prefetch_plan = "{\"shouldRun\":true,\"databasePath\":\"replica\",\"pauseBetweenRunsMs\":50,\"steps\":[{\"type\":\"prefetch-database\",\"data\":{}}]}";

test "a prefetch pass finishes the work, and marks the replica complete, when it fetches nothing and finds nothing missing" {
    var pass_services = newPassServices(&.{prefetch_plan}, &.{ok});
    defer pass_services.deinit();
    var state: ReplicaState = .unknown;
    const result = background_work.runPrefetchPass(std.testing.io, pass_services.passAllocator(), test_timers.timers(), pass_services.passServices(), &state);
    try std.testing.expectEqual(ReplicaState.complete, state);
    try expectEvents(&pass_services, &.{
        "plan plan-prefetch",
        "awake true",
        "report Filling in \"replica\".",
        "step prefetch-database",
        "report \"replica\" is filled in; nothing left to fetch.",
        "awake false",
    });
    try expectResult(50, true, result);
}

test "a prefetch pass is working while it fetches files, and stalled when it fetches nothing and files are still missing" {
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
    var pass_services = newPassServices(&.{prefetch_plan}, &.{fetched});
    var state: ReplicaState = .unknown;
    try expectResult(50, false, background_work.runPrefetchPass(std.testing.io, pass_services.passAllocator(), test_timers.timers(), pass_services.passServices(), &state));
    try std.testing.expectEqual(ReplicaState.working, state);
    pass_services.deinit();

    pass_services = newPassServices(&.{prefetch_plan}, &.{stuck});
    defer pass_services.deinit();
    try expectResult(50, false, background_work.runPrefetchPass(std.testing.io, pass_services.passAllocator(), test_timers.timers(), pass_services.passServices(), &state));
    try std.testing.expectEqual(ReplicaState.stalled, state);
}

test "a prefetch pass is stalled and does not finish the work when a step does not succeed" {
    var pass_services = newPassServices(&.{prefetch_plan}, &.{failed});
    defer pass_services.deinit();
    var state: ReplicaState = .unknown;
    const result = background_work.runPrefetchPass(std.testing.io, pass_services.passAllocator(), test_timers.timers(), pass_services.passServices(), &state);
    try std.testing.expectEqual(ReplicaState.stalled, state);
    try std.testing.expectEqualStrings("error Prefetch step \"prefetch-database\" did not succeed.", pass_services.events.items[pass_services.events.items.len - 2]);
    try expectResult(50, false, result);
}

test "an import pass reports a step that did not succeed while it was being stopped" {
    const plan = "{\"shouldRun\":true,\"databasePath\":\"photos\",\"pauseBetweenRunsMs\":10,\"steps\":[{\"type\":\"first\",\"data\":{}},{\"type\":\"second\",\"data\":{}}]}";
    var pass_services = newPassServices(&.{plan}, &.{failed});
    pass_services.stop_after_steps = 1;
    defer pass_services.deinit();
    _ = background_work.runImportPass(std.testing.io, pass_services.passAllocator(), test_timers.timers(), pass_services.passServices());
    try expectEvents(&pass_services, &.{
        "plan plan-auto-import",
        "awake true",
        "report Automatic import running into \"photos\".",
        "step first",
        "error Automatic import step \"first\" did not succeed.",
        "awake false",
    });
}

test "a prefetch pass is stalled and reports a step that did not succeed while it was being stopped" {
    var pass_services = newPassServices(&.{prefetch_plan}, &.{failed});
    pass_services.stop_after_steps = 1;
    defer pass_services.deinit();
    var state: ReplicaState = .unknown;
    _ = background_work.runPrefetchPass(std.testing.io, pass_services.passAllocator(), test_timers.timers(), pass_services.passServices(), &state);
    try std.testing.expectEqual(ReplicaState.stalled, state);
    try expectEvents(&pass_services, &.{
        "plan plan-prefetch",
        "awake true",
        "report Filling in \"replica\".",
        "step prefetch-database",
        "error Prefetch step \"prefetch-database\" did not succeed.",
        "awake false",
    });
}

test "a prefetch pass says why it is not running and does not finish the work" {
    const refused = "{\"shouldRun\":false,\"reason\":\"a prefetch is still filling this database in\",\"pauseBetweenRunsMs\":50,\"steps\":[]}";
    var pass_services = newPassServices(&.{refused}, &.{});
    defer pass_services.deinit();
    var state: ReplicaState = .unknown;
    const result = background_work.runPrefetchPass(std.testing.io, pass_services.passAllocator(), test_timers.timers(), pass_services.passServices(), &state);
    try expectEvents(&pass_services, &.{
        "plan plan-prefetch",
        "report No database to fill in: a prefetch is still filling this database in",
    });
    try std.testing.expectEqual(ReplicaState.unknown, state);
    try expectResult(50, false, result);
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

test "a task type is matched to its pass" {
    try std.testing.expectEqual(background_work.Pass.import, background_work.Pass.fromTaskType("background-auto-import").?);
    try std.testing.expectEqual(background_work.Pass.sync, background_work.Pass.fromTaskType("background-sync").?);
    try std.testing.expectEqual(background_work.Pass.prefetch, background_work.Pass.fromTaskType("background-prefetch").?);
    try std.testing.expect(background_work.Pass.fromTaskType("sync-database") == null);
}
