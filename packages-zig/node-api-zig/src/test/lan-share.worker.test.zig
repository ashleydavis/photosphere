const std = @import("std");
const task_queue_zig = @import("task-queue-zig");
const lan_share_network = @import("lan-share-network-zig");
const node_api = @import("node-api-zig");
const virtual_time_io = @import("../../../utils-zig/src/test/virtual-time-io.zig");
const test_environment = @import("test-environment.zig");
const recording_task_context = @import("recording-task-context.zig");
const test_task_context = @import("test-task-context.zig");
const node_utils = @import("node-utils-zig");
const receiveShareHandler = node_api.lan_share_worker.receiveShareHandler;
const findReceiverHandler = node_api.lan_share_worker.findReceiverHandler;
const sendPayloadHandler = node_api.lan_share_worker.sendPayloadHandler;
const LanShareReceiver = lan_share_network.lan_share_receiver.LanShareReceiver;
const LanShareSender = lan_share_network.lan_share_sender.LanShareSender;
const IReceiverEndpoint = lan_share_network.lan_share_types.IReceiverEndpoint;
const RecordingTaskContext = recording_task_context.RecordingTaskContext;
const TestTaskContext = test_task_context.TestTaskContext;
const TestUuidGenerator = node_utils.test_uuid_generator.TestUuidGenerator;
const TaskHandler = task_queue_zig.types.TaskHandler;

//
// Tests of the LAN share handlers. These
// run the real receiver and sender over the loopback interface: a test that needs the other side of a share (a sender for the receiver
// under test, a receiver for the sender under test) starts a real one, and a cancelled task is cancelled through its context.
//

//
// A sample secret payload.
//
fn sampleSecretPayload(allocator: std.mem.Allocator) !std.json.Value {
    var object: std.json.ObjectMap = .empty;
    try object.put(allocator, "type", .{ .string = "secret" });
    try object.put(allocator, "name", .{ .string = "aws" });
    try object.put(allocator, "secretType", .{ .string = "s3-credentials" });
    try object.put(allocator, "value", .{ .string = "{}" });
    return .{ .object = object };
}

//
// Builds task data holding the pairing code.
//
fn codeData(allocator: std.mem.Allocator, code: []const u8) !std.json.Value {
    var object: std.json.ObjectMap = .empty;
    try object.put(allocator, "code", .{ .string = code });
    return .{ .object = object };
}

//
// Builds the send-payload task data.
//
fn sendData(allocator: std.mem.Allocator, payload: std.json.Value, code: []const u8, endpoint: IReceiverEndpoint) !std.json.Value {
    var endpointObject: std.json.ObjectMap = .empty;
    try endpointObject.put(allocator, "address", .{ .string = endpoint.address });
    try endpointObject.put(allocator, "port", .{ .integer = endpoint.port });
    try endpointObject.put(allocator, "certFingerprint", .{ .string = endpoint.certFingerprint });
    var object: std.json.ObjectMap = .empty;
    try object.put(allocator, "payload", payload);
    try object.put(allocator, "code", .{ .string = code });
    try object.put(allocator, "endpoint", .{ .object = endpointObject });
    return .{ .object = object };
}

//
// Runs a handler on a thread of its own, because the handlers wait for the other side of a share.
//
const HandlerRun = struct {
    // Allocates for the handler. Used only by the handler's thread until it has finished.
    arena: std.heap.ArenaAllocator,

    // The Io the handler runs with.
    io: std.Io,

    // The handler.
    handler: TaskHandler,

    // The task data.
    data: std.json.Value,

    // The context of the task.
    context: *TestTaskContext,

    // What the handler returned.
    result: ?std.json.Value,

    // The error the handler returned.
    failure: ?anyerror,

    // The thread.
    thread: ?std.Thread,

    //
    // Starts the handler. The run must not move afterwards.
    //
    fn start(self: *HandlerRun, io: std.Io, handler: TaskHandler, data: std.json.Value, context: *TestTaskContext) !void {
        self.* = .{
            .arena = std.heap.ArenaAllocator.init(std.heap.page_allocator),
            .io = io,
            .handler = handler,
            .data = data,
            .context = context,
            .result = null,
            .failure = null,
            .thread = null,
        };
        self.thread = try std.Thread.spawn(.{}, run, .{self});
    }

    //
    // The thread: runs the handler.
    //
    fn run(self: *HandlerRun) void {
        self.result = self.handler(self.arena.allocator(), self.io, self.data, self.context.context.taskContext()) catch |err| {
            self.failure = err;
            return;
        };
    }

    //
    // Waits for the handler and returns what it returned.
    //
    fn finish(self: *HandlerRun) !std.json.Value {
        self.thread.?.join();
        self.thread = null;
        if (self.failure) |failure| {
            return failure;
        }
        return self.result.?;
    }

    //
    // Frees what the handler allocated.
    //
    fn deinit(self: *HandlerRun) void {
        // A test that fails before it has waited for the handler must not free what the handler is still using: the task is
        // cancelled, which ends a handler waiting for the other side of a share, and the thread is waited for.
        if (self.thread) |thread| {
            self.context.context.cancel();
            thread.join();
            self.thread = null;
        }
        self.arena.deinit();
    }
};

//
// Starts a sender on a thread that waits for a receiver, then starts the receiver and waits for the sender to find it, as the
// tests of lan-share-network-zig do. The sender is listening before the receiver starts, so it hears the announcement the
// receiver makes as it starts.
//
const IWaitOutcome = struct {
    // The endpoint the wait returned.
    endpoint: ?IReceiverEndpoint = null,

    // The error the wait returned, if any.
    failure: ?anyerror = null,
};

//
// Runs waitForReceiver on a thread of its own.
//
fn waitOnThread(sender: *LanShareSender, outcome: *IWaitOutcome) void {
    outcome.endpoint = sender.waitForReceiver(std.testing.io, 60000) catch |err| {
        outcome.failure = err;
        return;
    };
}

//
// Starts the receiver and finds it with a sender that holds the receiver's code.
//
fn startAndDiscover(receiver: *LanShareReceiver, sender: *LanShareSender, code: []const u8) !IReceiverEndpoint {
    var outcome: IWaitOutcome = .{};
    const waiting = try std.Thread.spawn(.{}, waitOnThread, .{ sender, &outcome });
    var attempts: usize = 0;
    while (!sender.isWaiting.load(.acquire)) {
        attempts += 1;
        if (attempts > 5000) {
            sender.cancel();
            waiting.join();
            return error.SenderNeverStartedListening;
        }
        try std.testing.io.sleep(.fromMilliseconds(1), .awake);
    }
    receiver.start(code) catch |err| {
        sender.cancel();
        waiting.join();
        return err;
    };
    waiting.join();
    try std.testing.expect(outcome.failure == null);
    try std.testing.expect(outcome.endpoint != null);
    return outcome.endpoint.?;
}

//
// The JSON text of a value.
//
fn jsonText(allocator: std.mem.Allocator, value: std.json.Value) ![]const u8 {
    return std.json.Stringify.valueAlloc(allocator, value, .{});
}

test "receiveShareHandler calls receiver.start with the supplied code and returns the delivered payload" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    _ = try test_environment.setupEnvironment(io);
    var context: TestTaskContext = undefined;
    var uuidGenerator = try TestUuidGenerator.init(allocator);
    context.init(uuidGenerator.uuidGenerator());
    const payload = try sampleSecretPayload(allocator);
    var run: HandlerRun = undefined;
    try run.start(io, receiveShareHandler, try codeData(allocator, "4242"), &context);
    defer run.deinit();

    // A sender holding the code finds the receiver the handler started and delivers the payload to it. A receiver started
    // with any other code would not be found, so this shows the handler started the receiver with the code it was given.
    var sender = try LanShareSender.init(allocator, io, payload, "4242");
    const endpoint = (try sender.waitForReceiver(io, 60000)) orelse {
        return error.ReceiverNotFound;
    };
    try std.testing.expect(try sender.send(endpoint));
    const result = try run.finish();

    try std.testing.expectEqualStrings(try jsonText(allocator, payload), try jsonText(allocator, result.object.get("payload").?));
    try std.testing.expectEqual(@as(u32, 1), result.object.count());
}

test "receiveShareHandler returns { payload: null } when no payload arrives before the timeout" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    // The clock moves when the receiver waits, so the sixty second timeout takes no real time.
    var virtualTime: virtual_time_io.VirtualTimeIo = undefined;
    virtualTime.init(std.testing.allocator);
    defer virtualTime.deinit();
    const io = virtualTime.io();
    _ = try test_environment.setupEnvironment(std.testing.io);
    var context: RecordingTaskContext = undefined;
    try context.init(allocator, null, null);

    const result = try receiveShareHandler(allocator, io, try codeData(allocator, "1111"), context.taskContext());

    try std.testing.expect(result.object.get("payload").? == .null);
}

test "receiveShareHandler cancels the receiver when the context reports cancellation and stops watching afterwards" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    _ = try test_environment.setupEnvironment(io);
    var context: RecordingTaskContext = undefined;
    try context.init(allocator, 0, null);

    const result = try receiveShareHandler(allocator, io, try codeData(allocator, "2222"), context.taskContext());

    try std.testing.expect(result.object.get("payload").? == .null);
    // The watcher asked once, cancelled the receiver and asked no more, and is no longer running once the handler has returned.
    try std.testing.expectEqual(@as(u64, 1), context.cancelChecks);
    try io.sleep(.fromMilliseconds(600), .awake);
    try std.testing.expectEqual(@as(u64, 1), context.cancelChecks);
}

test "findReceiverHandler constructs the sender with the code and returns the discovered endpoint" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    _ = try test_environment.setupEnvironment(io);
    var context: TestTaskContext = undefined;
    var uuidGenerator = try TestUuidGenerator.init(allocator);
    context.init(uuidGenerator.uuidGenerator());
    var run: HandlerRun = undefined;
    try run.start(io, findReceiverHandler, try codeData(allocator, "3333"), &context);
    defer run.deinit();
    var receiver = LanShareReceiver.init(io, 60000);
    defer receiver.deinit();

    // The handler's sender hears the receiver's announcement only when it holds the receiver's code.
    try receiver.start("3333");
    const result = try run.finish();

    const endpoint = result.object.get("endpoint").?.object;
    try std.testing.expectEqual(@as(i64, receiver.httpsPort), endpoint.get("port").?.integer);
    try std.testing.expect(endpoint.get("address").?.string.len > 0);
    try std.testing.expectEqual(@as(usize, 64), endpoint.get("certFingerprint").?.string.len);
    try std.testing.expectEqual(@as(u32, 3), endpoint.count());
}

test "findReceiverHandler returns { endpoint: null } on timeout" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    // The clock moves when the sender waits, so the sixty second timeout takes no real time.
    var virtualTime: virtual_time_io.VirtualTimeIo = undefined;
    virtualTime.init(std.testing.allocator);
    defer virtualTime.deinit();
    const io = virtualTime.io();
    _ = try test_environment.setupEnvironment(std.testing.io);
    var context: RecordingTaskContext = undefined;
    try context.init(allocator, null, null);

    // No receiver holds this code, so the wait ends only by timing out.
    const result = try findReceiverHandler(allocator, io, try codeData(allocator, "4444"), context.taskContext());

    try std.testing.expect(result.object.get("endpoint").? == .null);
}

test "findReceiverHandler cancels the sender when the context reports cancellation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    _ = try test_environment.setupEnvironment(io);
    var context: RecordingTaskContext = undefined;
    try context.init(allocator, 0, null);

    // No receiver holds this code, so only the cancellation can end the wait.
    const result = try findReceiverHandler(allocator, io, try codeData(allocator, "5555"), context.taskContext());

    try std.testing.expect(result.object.get("endpoint").? == .null);
    try std.testing.expectEqual(@as(u64, 1), context.cancelChecks);
}

test "sendPayloadHandler constructs the sender with payload/code, sends to the endpoint, and returns success true" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    _ = try test_environment.setupEnvironment(io);
    var context: RecordingTaskContext = undefined;
    try context.init(allocator, null, null);
    const payload = try sampleSecretPayload(allocator);
    var receiver = LanShareReceiver.init(io, 60000);
    defer receiver.deinit();
    var finder = try LanShareSender.init(allocator, io, .null, "6666");
    const endpoint = try startAndDiscover(&receiver, &finder, "6666");

    const result = try sendPayloadHandler(allocator, io, try sendData(allocator, payload, "6666", endpoint), context.taskContext());

    try std.testing.expect(result.object.get("success").?.bool);
    // The receiver was given the payload.
    const delivered = (try receiver.receive()).?;
    try std.testing.expectEqualStrings(try jsonText(allocator, payload), try jsonText(allocator, delivered));
}

test "sendPayloadHandler returns success false when the receiver rejects the payload" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    _ = try test_environment.setupEnvironment(io);
    var context: RecordingTaskContext = undefined;
    try context.init(allocator, null, null);
    const payload = try sampleSecretPayload(allocator);
    var receiver = LanShareReceiver.init(io, 60000);
    defer receiver.deinit();
    var finder = try LanShareSender.init(allocator, io, .null, "6666");
    const endpoint = try startAndDiscover(&receiver, &finder, "6666");

    // The receiver holds 6666 and the task is given 7777, so the receiver's pairing code hash does not match.
    const result = try sendPayloadHandler(allocator, io, try sendData(allocator, payload, "7777", endpoint), context.taskContext());

    try std.testing.expect(!result.object.get("success").?.bool);
}
