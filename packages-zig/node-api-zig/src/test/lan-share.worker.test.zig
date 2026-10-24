const std = @import("std");
const test_timers = @import("test-timers.zig");
const task_queue_zig = @import("ziggy").task_queue;
const lan_share_network = @import("lan-share-network-zig");
const node_api = @import("node-api-zig");
const virtual_time_io = @import("../../../utils-zig/src/test/virtual-time-io.zig");
const test_environment = @import("test-environment.zig");
const recording_task_context = @import("recording-task-context.zig");
const node_utils = @import("node-utils-zig");
const utils = @import("utils-zig");
const thread_messages = @import("../../../utils-zig/src/test/thread-messages.zig");
const receiveShareHandler = node_api.lan_share_worker.receiveShareHandler;
const findReceiverHandler = node_api.lan_share_worker.findReceiverHandler;
const sendPayloadHandler = node_api.lan_share_worker.sendPayloadHandler;
const LanShareReceiver = lan_share_network.lan_share_receiver.LanShareReceiver;
const LanShareSender = lan_share_network.lan_share_sender.LanShareSender;
const IReceiverEndpoint = lan_share_network.lan_share_types.IReceiverEndpoint;
const RecordingTaskContext = recording_task_context.RecordingTaskContext;
const TestUuidGenerator = node_utils.test_uuid_generator.TestUuidGenerator;
const TestTimestampProvider = node_utils.test_timestamp_provider.TestTimestampProvider;
const TaskHandler = task_queue_zig.types.TaskHandler;
const ITaskContext = task_queue_zig.types.ITaskContext;
const MessageQueue = thread_messages.MessageQueue;
const ThreadAllocator = thread_messages.ThreadAllocator;

//
// Tests of the LAN share handlers. These
// run the real receiver and sender over the loopback interface: a test that needs the other side of a share (a sender for the receiver
// under test, a receiver for the sender under test) starts a real one, and a cancelled task is cancelled through its context.
//
// A test shares nothing with a thread it starts: the thread makes its own allocator, Io, receiver or task context, from copies of
// what it needs given as JSON on its queue of orders, and posts what it found to the test's queue of events.
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
// The cancel a test posts to a thread it started.
//
const ICancel = struct {
    cancel: bool,
};

//
// A task context made on a handler's thread, whose events go nowhere and whose task is cancelled when the test posts an ICancel to
// the thread's orders: the context looks for it each time the handler asks whether the task is cancelled, as a worker's context
// looks at the worker's queue.
// The context must not move while it is used.
//
const CancelledByMessage = struct {
    // Deterministic time.
    timestampProvider: TestTimestampProvider,

    // The generator of identifiers, made on the handler's thread.
    uuidGenerator: TestUuidGenerator,

    // The orders of the handler's thread, where the test's cancel comes.
    orders: *MessageQueue,

    // Whether the test's cancel has come.
    cancelled: bool,

    //
    // The ITaskContext functions of this context.
    //
    const vtable: ITaskContext.VTable = .{
        .sendEvent = ignoreEvent,
        .isCancelled = isCancelled,
    };

    //
    // The context as a handler takes it. The session id is "test-session" and the task id "test-task".
    //
    fn taskContext(self: *CancelledByMessage) ITaskContext {
        return .{
            .uuidGenerator = self.uuidGenerator.uuidGenerator(),
            .timestampProvider = self.timestampProvider.timestampProvider(),
            .sessionId = "test-session",
            .taskId = "test-task",
            .maxConcurrentChildTasks = 10,
            .nativeCaller = null,
            .ptr = self,
            .vtable = &vtable,
        };
    }

    //
    // Drops an event.
    //
    fn ignoreEvent(_: *anyopaque, _: std.Io, _: std.mem.Allocator, _: std.json.Value) void {}

    //
    // Whether the test has cancelled the task, looking for its cancel among the thread's orders with the handler's Io and allocator.
    //
    fn isCancelled(ptr: *anyopaque, io: std.Io, allocator: std.mem.Allocator) bool {
        const self: *CancelledByMessage = @ptrCast(@alignCast(ptr));
        if (!self.cancelled) {
            if (self.orders.tryTake(io, allocator)) |message| {
                allocator.free(message.text);
                self.cancelled = true;
            }
        }
        return self.cancelled;
    }
};

//
// The handlers a HandlerRun runs.
//
const IHandlerKind = enum {
    receive_share,
    find_receiver,
};

//
// One variable of an environment, as a thread is given it.
//
const IVariable = struct {
    name: []const u8,
    value: []const u8,
};

//
// What a handler's thread is given: the handler, its task data and a copy of the test's environment, which the thread makes its own,
// as a worker is given one: the environment is the calling thread's, and it names the discovery port of the test.
//
const IHandlerOrder = struct {
    handler: IHandlerKind,
    data: std.json.Value,
    environment: []const IVariable,
};

//
// What a handler's thread tells the test once the handler has returned: what it returned, or the name of its error.
//
const IHandlerOutcome = struct {
    result: ?std.json.Value,
    failure: ?[]const u8,
};

//
// Runs a handler on a thread of its own, because the handlers wait for the other side of a share.
//
const HandlerRun = struct {
    // The thread, until the test has waited for it.
    thread: ?std.Thread,

    // The thread's orders: the IHandlerOrder, then the test's cancel, if the test cancels.
    orders: MessageQueue,

    // What the thread tells the test.
    outcomes: MessageQueue,

    //
    // Starts the handler. The run must not move afterwards.
    //
    fn start(self: *HandlerRun, io: std.Io, allocator: std.mem.Allocator, handler: IHandlerKind, data: std.json.Value) !void {
        self.* = .{
            .thread = null,
            .orders = MessageQueue.init(),
            .outcomes = MessageQueue.init(),
        };
        var environment: std.ArrayList(IVariable) = .empty;
        var variables = test_environment.getEnvironment().iterator();
        while (variables.next()) |entry| {
            try environment.append(allocator, .{
                .name = entry.key_ptr.*,
                .value = entry.value_ptr.*,
            });
        }
        try thread_messages.post(&self.orders, io, allocator, IHandlerOrder{
            .handler = handler,
            .data = data,
            .environment = environment.items,
        });
        self.thread = try std.Thread.spawn(.{}, run, .{ &self.orders, &self.outcomes });
    }

    //
    // The thread: makes its own allocator, Io and task context, takes its order, runs the handler and tells the test what it
    // returned.
    //
    fn run(orders: *MessageQueue, outcomes: *MessageQueue) void {
        var thread_allocator: ThreadAllocator = .init;
        defer thread_allocator.deinit();
        var arena_state = std.heap.ArenaAllocator.init(thread_allocator.allocator());
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        var threaded: std.Io.Threaded = .init(thread_allocator.allocator(), .{});
        defer threaded.deinit();
        const io = threaded.io();
        const order = thread_messages.take(IHandlerOrder, orders, io, arena) catch |err| {
            std.debug.panic("The handler's thread got no order: {s}", .{@errorName(err)});
        };
        var environment = std.process.Environ.Map.init(arena);
        for (order.environment) |variable| {
            environment.put(variable.name, variable.value) catch @panic("out of memory making the environment");
        }
        node_utils.process_env.setEnvironMap(&environment);
        defer node_utils.process_env.setEnvironMap(null);
        var context: CancelledByMessage = .{
            .timestampProvider = .{},
            .uuidGenerator = TestUuidGenerator.init(arena) catch @panic("out of memory making the generator of identifiers"),
            .orders = orders,
            .cancelled = false,
        };
        const handler: TaskHandler = switch (order.handler) {
            .receive_share => receiveShareHandler,
            .find_receiver => findReceiverHandler,
        };
        var outcome: IHandlerOutcome = .{
            .result = null,
            .failure = null,
        };
        if (handler(arena, io, test_timers.timers(), order.data, context.taskContext())) |result| {
            outcome.result = result;
        }
        else |err| {
            outcome.failure = @errorName(err);
        }
        thread_messages.post(outcomes, io, arena, outcome) catch @panic("out of memory telling the test what the handler returned");
    }

    //
    // Waits for the handler and returns what it returned, in the allocator.
    //
    fn finish(self: *HandlerRun, io: std.Io, allocator: std.mem.Allocator) !std.json.Value {
        self.thread.?.join();
        self.thread = null;
        const outcome = try thread_messages.take(IHandlerOutcome, &self.outcomes, io, allocator);
        if (outcome.failure) |failure| {
            return utils.errors.throwError("The handler failed: {s}", .{failure});
        }
        return outcome.result.?;
    }

    //
    // Ends the run.
    //
    fn deinit(self: *HandlerRun, io: std.Io, allocator: std.mem.Allocator) void {
        // A test that fails before it has waited for the handler must not end the run under it: the task is cancelled, which ends a
        // handler waiting for the other side of a share, and the thread is waited for.
        if (self.thread) |thread| {
            thread_messages.post(&self.orders, io, allocator, ICancel{
                .cancel = true,
            }) catch @panic("out of memory cancelling the handler");
            thread.join();
            self.thread = null;
        }
        self.orders.deinit();
        self.outcomes.deinit();
    }
};

//
// What a receiver's thread is given: the discovery port it announces itself to and the pairing code it is started with.
//
const IReceiverOrder = struct {
    discoveryPort: u16,
    code: []const u8,
};

//
// What a receiver's thread tells the test once it has started: the port of its HTTPS server, or the name of the error that stopped
// it starting.
//
const IReceiverStarted = struct {
    httpsPort: u16,
    failure: ?[]const u8,
};

//
// What a receiver's thread tells the test once its receive has ended: the payload it received, or null.
//
const IReceiverFinished = struct {
    payload: ?std.json.Value,
};

//
// A real receiver on a thread of its own, which makes the receiver and runs its receive: the receiver serves connections, and
// announces itself every second, only while it receives. The test cancels it by posting an ICancel, which the thread looks for
// between the receive's slices.
//
const ReceiverRun = struct {
    // The thread, until the test has waited for it.
    thread: ?std.Thread,

    // The thread's orders: the IReceiverOrder, then the test's cancel, if the test cancels.
    orders: MessageQueue,

    // What the thread tells the test.
    events: MessageQueue,

    // The port of the receiver's HTTPS server, as the thread told the test.
    httpsPort: u16,

    //
    // Starts the receiver with the code on its thread and waits for it to have started. The run must not move afterwards.
    //
    fn start(self: *ReceiverRun, io: std.Io, allocator: std.mem.Allocator, code: []const u8) !void {
        self.* = .{
            .thread = null,
            .orders = MessageQueue.init(),
            .events = MessageQueue.init(),
            .httpsPort = 0,
        };
        try thread_messages.post(&self.orders, io, allocator, IReceiverOrder{
            .discoveryPort = try lan_share_network.lan_share_types.discoveryPort(),
            .code = code,
        });
        self.thread = try std.Thread.spawn(.{}, run, .{ &self.orders, &self.events });
        const started = try thread_messages.take(IReceiverStarted, &self.events, io, allocator);
        if (started.failure) |failure| {
            self.thread.?.join();
            self.thread = null;
            return utils.errors.throwError("The receiver did not start: {s}", .{failure});
        }
        self.httpsPort = started.httpsPort;
    }

    //
    // The thread: makes its own allocator, Io and receiver, starts it, tells the test its port, receives until a payload, the
    // timeout or the test's cancel, and tells the test what it received.
    //
    fn run(orders: *MessageQueue, events: *MessageQueue) void {
        var thread_allocator: ThreadAllocator = .init;
        defer thread_allocator.deinit();
        var arena_state = std.heap.ArenaAllocator.init(thread_allocator.allocator());
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        var threaded: std.Io.Threaded = .init(thread_allocator.allocator(), .{});
        defer threaded.deinit();
        const io = threaded.io();
        const order = thread_messages.take(IReceiverOrder, orders, io, arena) catch |err| {
            std.debug.panic("The receiver's thread got no order: {s}", .{@errorName(err)});
        };
        var receiver = LanShareReceiver.init(order.discoveryPort, io, 60000);
        defer receiver.deinit();
        receiver.start(order.code) catch |err| {
            thread_messages.post(events, io, arena, IReceiverStarted{
                .httpsPort = 0,
                .failure = @errorName(err),
            }) catch @panic("out of memory telling the test the receiver did not start");
            return;
        };
        thread_messages.post(events, io, arena, IReceiverStarted{
            .httpsPort = receiver.httpsPort,
            .failure = null,
        }) catch @panic("out of memory telling the test the receiver started");
        while (receiver.receiveStep()) {
            if (orders.tryTake(io, arena)) |_| {
                receiver.cancel();
            }
        }
        thread_messages.post(events, io, arena, IReceiverFinished{
            .payload = receiver.finishReceive(),
        }) catch @panic("out of memory telling the test what the receiver received");
    }

    //
    // Waits for the receive to end and returns what it received, in the allocator.
    //
    fn finish(self: *ReceiverRun, io: std.Io, allocator: std.mem.Allocator) !?std.json.Value {
        self.thread.?.join();
        self.thread = null;
        return (try thread_messages.take(IReceiverFinished, &self.events, io, allocator)).payload;
    }

    //
    // Cancels the receive and waits for it, if the test has not already, and ends the run.
    //
    fn stop(self: *ReceiverRun, io: std.Io, allocator: std.mem.Allocator) void {
        if (self.thread) |thread| {
            thread_messages.post(&self.orders, io, allocator, ICancel{
                .cancel = true,
            }) catch @panic("out of memory cancelling the receiver");
            thread.join();
            self.thread = null;
        }
        self.orders.deinit();
        self.events.deinit();
    }
};

//
// What a sender's wait for a receiver returned.
//
const IWaitOutcome = struct {
    // The endpoint the wait returned.
    endpoint: ?IReceiverEndpoint = null,

    // The error the wait returned, if any.
    failure: ?anyerror = null,
};

//
// Finds a receiver that a ReceiverRun has started with a sender that holds the receiver's code. The receiver announces itself every
// second while it receives, so the sender hears it whenever it starts listening.
//
fn discover(sender: *LanShareSender, io: std.Io) !IReceiverEndpoint {
    var outcome: IWaitOutcome = .{};
    outcome.endpoint = sender.waitForReceiver(io, 60000) catch |err| failed: {
        outcome.failure = err;
        break :failed null;
    };
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
    const test_env = try test_environment.setupEnvironment(io);
    defer test_env.deinit();
    const payload = try sampleSecretPayload(allocator);
    var run: HandlerRun = undefined;
    try run.start(io, allocator, .receive_share, try codeData(allocator, "4242"));
    defer run.deinit(io, allocator);

    // A sender holding the code finds the receiver the handler started and delivers the payload to it. A receiver started
    // with any other code would not be found, so this shows the handler started the receiver with the code it was given.
    var sender = try LanShareSender.init(try lan_share_network.lan_share_types.discoveryPort(), allocator, io, payload, "4242");
    const endpoint = (try sender.waitForReceiver(io, 60000)) orelse {
        return error.ReceiverNotFound;
    };
    try std.testing.expect(try sender.send(endpoint));
    const result = try run.finish(io, allocator);

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
    const test_env = try test_environment.setupEnvironment(std.testing.io);
    defer test_env.deinit();
    var context: RecordingTaskContext = undefined;
    try context.init(allocator, null, null);

    const result = try receiveShareHandler(allocator, io, test_timers.timers(), try codeData(allocator, "1111"), context.taskContext());

    try std.testing.expect(result.object.get("payload").? == .null);
}

test "receiveShareHandler cancels the receiver when the context reports cancellation and stops watching afterwards" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const test_env = try test_environment.setupEnvironment(io);
    defer test_env.deinit();
    var context: RecordingTaskContext = undefined;
    try context.init(allocator, 0, null);

    const result = try receiveShareHandler(allocator, io, test_timers.timers(), try codeData(allocator, "2222"), context.taskContext());

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
    const test_env = try test_environment.setupEnvironment(io);
    defer test_env.deinit();
    var run: HandlerRun = undefined;
    try run.start(io, allocator, .find_receiver, try codeData(allocator, "3333"));
    defer run.deinit(io, allocator);
    var receiving: ReceiverRun = undefined;

    // The handler's sender hears the receiver's announcement only when it holds the receiver's code.
    try receiving.start(io, allocator, "3333");
    defer receiving.stop(io, allocator);
    const result = try run.finish(io, allocator);

    const endpoint = result.object.get("endpoint").?.object;
    try std.testing.expectEqual(@as(i64, receiving.httpsPort), endpoint.get("port").?.integer);
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
    const test_env = try test_environment.setupEnvironment(std.testing.io);
    defer test_env.deinit();
    var context: RecordingTaskContext = undefined;
    try context.init(allocator, null, null);

    // No receiver holds this code, so the wait ends only by timing out.
    const result = try findReceiverHandler(allocator, io, test_timers.timers(), try codeData(allocator, "4444"), context.taskContext());

    try std.testing.expect(result.object.get("endpoint").? == .null);
}

test "findReceiverHandler cancels the sender when the context reports cancellation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const test_env = try test_environment.setupEnvironment(io);
    defer test_env.deinit();
    var context: RecordingTaskContext = undefined;
    try context.init(allocator, 0, null);

    // No receiver holds this code, so only the cancellation can end the wait.
    const result = try findReceiverHandler(allocator, io, test_timers.timers(), try codeData(allocator, "5555"), context.taskContext());

    try std.testing.expect(result.object.get("endpoint").? == .null);
    try std.testing.expectEqual(@as(u64, 1), context.cancelChecks);
}

test "sendPayloadHandler constructs the sender with payload/code, sends to the endpoint, and returns success true" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const test_env = try test_environment.setupEnvironment(io);
    defer test_env.deinit();
    var context: RecordingTaskContext = undefined;
    try context.init(allocator, null, null);
    const payload = try sampleSecretPayload(allocator);
    var receiving: ReceiverRun = undefined;
    try receiving.start(io, allocator, "6666");
    defer receiving.stop(io, allocator);
    var finder = try LanShareSender.init(try lan_share_network.lan_share_types.discoveryPort(), allocator, io, .null, "6666");
    const endpoint = try discover(&finder, io);

    const result = try sendPayloadHandler(allocator, io, test_timers.timers(), try sendData(allocator, payload, "6666", endpoint), context.taskContext());

    try std.testing.expect(result.object.get("success").?.bool);
    // The receiver was given the payload.
    const delivered = (try receiving.finish(io, allocator)).?;
    try std.testing.expectEqualStrings(try jsonText(allocator, payload), try jsonText(allocator, delivered));
}

test "sendPayloadHandler returns success false when the receiver rejects the payload" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const test_env = try test_environment.setupEnvironment(io);
    defer test_env.deinit();
    var context: RecordingTaskContext = undefined;
    try context.init(allocator, null, null);
    const payload = try sampleSecretPayload(allocator);
    var receiving: ReceiverRun = undefined;
    try receiving.start(io, allocator, "6666");
    defer receiving.stop(io, allocator);
    var finder = try LanShareSender.init(try lan_share_network.lan_share_types.discoveryPort(), allocator, io, .null, "6666");
    const endpoint = try discover(&finder, io);

    // The receiver holds 6666 and the task is given 7777, so the receiver's pairing code hash does not match.
    const result = try sendPayloadHandler(allocator, io, test_timers.timers(), try sendData(allocator, payload, "7777", endpoint), context.taskContext());

    try std.testing.expect(!result.object.get("success").?.bool);
}
