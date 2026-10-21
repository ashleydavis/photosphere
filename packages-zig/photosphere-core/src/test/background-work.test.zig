const std = @import("std");
const background_work = @import("photosphere-core").background_work;

const PassHost = background_work.PassHost;
const IPassResult = background_work.IPassResult;
const IStep = background_work.IStep;
const IStepResult = background_work.IStepResult;
const ReplicaState = background_work.ReplicaState;

//
// A host that plays back what a test scripts: the outputs of each planning task and the result of each step. It records everything the
// pass did, in order, and owns an arena the pass allocates from.
//
const ScriptedHost = struct {
    // Allocates the records.
    allocator: std.mem.Allocator,
    // What the pass allocates from, freed with the host.
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
    // How many steps run before the host says the pass was stopped, or null when it is never stopped that way.
    stop_after_steps: ?usize,

    const vtable: PassHost.VTable = .{
        .readPlan = readPlan,
        .runStep = runStep,
        .holdAwake = holdAwake,
        .report = report,
        .reportError = reportError,
        .isStopped = isStopped,
    };

    fn host(self: *ScriptedHost) PassHost {
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
        if (self.last_plan_request) |text| {
            self.allocator.free(text);
        }
        self.arena.deinit();
    }

    // What the pass allocates from.
    fn passAllocator(self: *ScriptedHost) std.mem.Allocator {
        return self.arena.allocator();
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
        const self: *ScriptedHost = @ptrCast(@alignCast(ptr));
        const limit = self.stop_after_steps orelse {
            return false;
        };
        return self.steps_run >= limit;
    }
};

fn newHost(plans: []const []const u8, step_results: []const IStepResult) ScriptedHost {
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

fn expectResult(expected_gap_ms: u64, expected_finished: bool, result: IPassResult) !void {
    try std.testing.expectEqual(expected_gap_ms, result.gap_ms);
    try std.testing.expectEqual(expected_finished, result.finished);
}

test "an import pass finishes the work when the plan says automatic import is switched off" {
    var host = newHost(&.{"{\"shouldRun\":false,\"pauseBetweenRunsMs\":1000,\"steps\":[]}"}, &.{});
    defer host.deinit();
    const result = background_work.runImportPass(host.passAllocator(), host.host());
    try expectEvents(&host, &.{
        "plan plan-auto-import",
        "report Automatic import is switched off.",
    });
    try expectResult(1000, true, result);
}

test "an import pass runs the steps in order with the phone held awake, and asks for the gap the plan gave" {
    const plan = "{\"shouldRun\":true,\"databasePath\":\"photos\",\"pauseBetweenRunsMs\":7000,\"steps\":[{\"type\":\"create-default-database\",\"data\":{}},{\"type\":\"import-assets\",\"data\":{\"a\":1}}]}";
    var host = newHost(&.{plan}, &.{ ok, ok });
    defer host.deinit();
    const result = background_work.runImportPass(host.passAllocator(), host.host());
    try expectEvents(&host, &.{
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
    var host = newHost(&.{}, &.{});
    host.plan_fails = true;
    defer host.deinit();
    const result = background_work.runImportPass(host.passAllocator(), host.host());
    try expectEvents(&host, &.{
        "plan plan-auto-import",
        "error Could not work out what automatic import should do: PlanTaskFailed",
    });
    try expectResult(background_work.FALLBACK_PAUSE_MS, false, result);
}

test "an import pass abandons the rest of its steps when one does not succeed, and does not finish the work" {
    const plan = "{\"shouldRun\":true,\"databasePath\":\"photos\",\"pauseBetweenRunsMs\":10,\"steps\":[{\"type\":\"first\",\"data\":{}},{\"type\":\"second\",\"data\":{}}]}";
    var host = newHost(&.{plan}, &.{failed});
    defer host.deinit();
    const result = background_work.runImportPass(host.passAllocator(), host.host());
    try expectEvents(&host, &.{
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
    var host = newHost(&.{plan}, &.{});
    defer host.deinit();
    const result = background_work.runImportPass(host.passAllocator(), host.host());
    try expectResult(background_work.FALLBACK_PAUSE_MS, false, result);
}

test "a sync pass tells the plan what the prefetch is doing, and says why it is not syncing" {
    const plan = "{\"shouldRun\":false,\"reason\":\"syncing is off\",\"pauseBetweenRunsMs\":0,\"steps\":[]}";
    var host = newHost(&.{plan}, &.{});
    defer host.deinit();
    var state: std.atomic.Value(ReplicaState) = .init(.working);
    const result = background_work.runSyncPass(host.passAllocator(), host.host(), &state, false);
    try expectEvents(&host, &.{
        "plan plan-sync",
        "report Not syncing: syncing is off",
    });
    try std.testing.expectEqualStrings("{\"prefetchState\":\"working\"}", host.last_plan_request.?);
    try expectResult(background_work.SYNC_FALLBACK_PAUSE_MS, false, result);
}

test "a sync pass runs the sync step with the phone held awake" {
    const plan = "{\"shouldRun\":true,\"databasePath\":\"photos\",\"pauseBetweenRunsMs\":300,\"steps\":[{\"type\":\"sync-database\",\"data\":{}}]}";
    var host = newHost(&.{plan}, &.{ok});
    defer host.deinit();
    var state: std.atomic.Value(ReplicaState) = .init(.unknown);
    const result = background_work.runSyncPass(host.passAllocator(), host.host(), &state, false);
    try expectEvents(&host, &.{
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
    var host = newHost(&.{plan}, &.{ok});
    defer host.deinit();
    var state: std.atomic.Value(ReplicaState) = .init(.unknown);
    const result = background_work.runSyncPass(host.passAllocator(), host.host(), &state, true);
    try expectEvents(&host, &.{
        "plan plan-sync",
    });
    try expectResult(300, false, result);
}

const prefetch_plan = "{\"shouldRun\":true,\"databasePath\":\"replica\",\"pauseBetweenRunsMs\":50,\"steps\":[{\"type\":\"prefetch-database\",\"data\":{}}]}";

test "a prefetch pass finishes the work, and marks the replica complete, when it fetches nothing and finds nothing missing" {
    var host = newHost(&.{prefetch_plan}, &.{ok});
    defer host.deinit();
    var state: std.atomic.Value(ReplicaState) = .init(.unknown);
    const result = background_work.runPrefetchPass(host.passAllocator(), host.host(), &state);
    try std.testing.expectEqual(ReplicaState.complete, state.load(.acquire));
    try expectEvents(&host, &.{
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
    var host = newHost(&.{prefetch_plan}, &.{fetched});
    var state: std.atomic.Value(ReplicaState) = .init(.unknown);
    try expectResult(50, false, background_work.runPrefetchPass(host.passAllocator(), host.host(), &state));
    try std.testing.expectEqual(ReplicaState.working, state.load(.acquire));
    host.deinit();

    host = newHost(&.{prefetch_plan}, &.{stuck});
    defer host.deinit();
    try expectResult(50, false, background_work.runPrefetchPass(host.passAllocator(), host.host(), &state));
    try std.testing.expectEqual(ReplicaState.stalled, state.load(.acquire));
}

test "a prefetch pass is stalled and does not finish the work when a step does not succeed" {
    var host = newHost(&.{prefetch_plan}, &.{failed});
    defer host.deinit();
    var state: std.atomic.Value(ReplicaState) = .init(.unknown);
    const result = background_work.runPrefetchPass(host.passAllocator(), host.host(), &state);
    try std.testing.expectEqual(ReplicaState.stalled, state.load(.acquire));
    try std.testing.expectEqualStrings("error Prefetch step \"prefetch-database\" did not succeed.", host.events.items[host.events.items.len - 2]);
    try expectResult(50, false, result);
}

test "an import pass reports a step that did not succeed while it was being stopped" {
    const plan = "{\"shouldRun\":true,\"databasePath\":\"photos\",\"pauseBetweenRunsMs\":10,\"steps\":[{\"type\":\"first\",\"data\":{}},{\"type\":\"second\",\"data\":{}}]}";
    var host = newHost(&.{plan}, &.{failed});
    host.stop_after_steps = 1;
    defer host.deinit();
    _ = background_work.runImportPass(host.passAllocator(), host.host());
    try expectEvents(&host, &.{
        "plan plan-auto-import",
        "awake true",
        "report Automatic import running into \"photos\".",
        "step first",
        "error Automatic import step \"first\" did not succeed.",
        "awake false",
    });
}

test "a prefetch pass is stalled and reports a step that did not succeed while it was being stopped" {
    var host = newHost(&.{prefetch_plan}, &.{failed});
    host.stop_after_steps = 1;
    defer host.deinit();
    var state: std.atomic.Value(ReplicaState) = .init(.unknown);
    _ = background_work.runPrefetchPass(host.passAllocator(), host.host(), &state);
    try std.testing.expectEqual(ReplicaState.stalled, state.load(.acquire));
    try expectEvents(&host, &.{
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
    var host = newHost(&.{refused}, &.{});
    defer host.deinit();
    var state: std.atomic.Value(ReplicaState) = .init(.unknown);
    const result = background_work.runPrefetchPass(host.passAllocator(), host.host(), &state);
    try expectEvents(&host, &.{
        "plan plan-prefetch",
        "report No database to fill in: a prefetch is still filling this database in",
    });
    try std.testing.expectEqual(ReplicaState.unknown, state.load(.acquire));
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
