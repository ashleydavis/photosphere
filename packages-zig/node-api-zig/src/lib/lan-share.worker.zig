const std = @import("std");
const task_queue_zig = @import("ziggy-core").task_queue;
const api = @import("api-zig");
const lan_share_network = @import("lan-share-network-zig");
const ITaskContext = task_queue_zig.types.ITaskContext;
const LanShareReceiver = lan_share_network.lan_share_receiver.LanShareReceiver;
const LanShareSender = lan_share_network.lan_share_sender.LanShareSender;
const IReceiverEndpoint = lan_share_network.lan_share_types.IReceiverEndpoint;
const IReceiveShareTaskData = api.lan_share.IReceiveShareTaskData;
const IReceiveShareTaskResult = api.lan_share.IReceiveShareTaskResult;
const IFindReceiverTaskData = api.lan_share.IFindReceiverTaskData;
const IFindReceiverTaskResult = api.lan_share.IFindReceiverTaskResult;
const ISendPayloadTaskData = api.lan_share.ISendPayloadTaskData;
const ISendPayloadTaskResult = api.lan_share.ISendPayloadTaskResult;

//
// How long a receiver or sender waits (in milliseconds) before giving up.
//
const SHARE_TIMEOUT_MS = 60000;

//
// How often (in milliseconds) to poll the task context for cancellation.
//
const CANCEL_POLL_INTERVAL_MS = 250;

//
// How long (in milliseconds) the cancellation watcher sleeps at a time, so that stopping it does not wait out a whole
// CANCEL_POLL_INTERVAL_MS.
//
const WATCHER_SLEEP_SLICE_MS = 10;

//
// Polls the task context for cancellation on a thread of its own and calls the cancel function the first time the task
// is reported cancelled.
// The cancel function is called from the watcher's thread, so it must be one that is safe to call from another thread, as
// LanShareReceiver.cancel and LanShareSender.cancel are. The watcher must not move once started.
//
const CancellationWatcher = struct {
    // The context polled for cancellation.
    context: ITaskContext,

    // The Io the watcher sleeps with.
    io: std.Io,

    // The object whose cancel function is called.
    target: *anyopaque,

    // Cancels the target.
    cancelTarget: *const fn (target: *anyopaque) void,

    // Set by stop to end the watcher's thread.
    isStopped: std.atomic.Value(bool),

    // The thread that polls.
    thread: ?std.Thread,

    //
    // Starts polling.
    //
    fn start(self: *CancellationWatcher, context: ITaskContext, io: std.Io, target: *anyopaque, cancelTarget: *const fn (target: *anyopaque) void) !void {
        self.* = .{
            .context = context,
            .io = io,
            .target = target,
            .cancelTarget = cancelTarget,
            .isStopped = .init(false),
            .thread = null,
        };
        self.thread = try std.Thread.spawn(.{}, poll, .{self});
    }

    //
    // The polling thread: checks the context every CANCEL_POLL_INTERVAL_MS until stopped.
    //
    fn poll(self: *CancellationWatcher) void {
        var cancelled = false;
        while (!self.isStopped.load(.acquire)) {
            var waited: u64 = 0;
            while (waited < CANCEL_POLL_INTERVAL_MS and !self.isStopped.load(.acquire)) {
                // The watcher's thread is not a task of the Io, so nothing can cancel its sleep. Should one be cancelled all the
                // same, the task could no longer be cancelled from the interface, so that is a crash rather than a quiet stop.
                self.io.sleep(.fromMilliseconds(WATCHER_SLEEP_SLICE_MS), .awake) catch |err| {
                    std.debug.panic("The cancellation watcher of a LAN share task could not sleep: {s}", .{@errorName(err)});
                };
                waited += WATCHER_SLEEP_SLICE_MS;
            }
            if (self.isStopped.load(.acquire)) {
                return;
            }
            if (!cancelled and self.context.isCancelled()) {
                cancelled = true;
                self.cancelTarget(self.target);
            }
        }
    }

    //
    // Stops polling.
    //
    fn stop(self: *CancellationWatcher) void {
        self.isStopped.store(true, .release);
        if (self.thread) |thread| {
            thread.join();
            self.thread = null;
        }
    }
};

//
// Cancels the receiver.
//
fn cancelReceiver(target: *anyopaque) void {
    const receiver: *LanShareReceiver = @ptrCast(@alignCast(target));
    receiver.cancel();
}

//
// Cancels the sender.
//
fn cancelSender(target: *anyopaque) void {
    const sender: *LanShareSender = @ptrCast(@alignCast(target));
    sender.cancel();
}

//
// "receive-share" background-task handler. Hosts a LAN receiver advertising the
// supplied pairing code and waits for a sender to deliver a payload.
// Returns the delivered payload, or null on timeout or cancellation.
// (Zig: the task data and output are JSON values holding IReceiveShareTaskData and IReceiveShareTaskResult. The
// receiver is deinitialised when the handler returns, which frees the payload it holds, so the payload is copied
// with the task's allocator first.)
//
pub fn receiveShareHandler(allocator: std.mem.Allocator, io: std.Io, taskData: std.json.Value, context: ITaskContext) anyerror!std.json.Value {
    const data = try std.json.parseFromValueLeaky(IReceiveShareTaskData, allocator, taskData, .{
        .ignore_unknown_fields = true,
    });
    var receiver = LanShareReceiver.init(try lan_share_network.lan_share_types.discoveryPort(), io, SHARE_TIMEOUT_MS);
    defer receiver.deinit();
    try receiver.start(data.code);

    var watcher: CancellationWatcher = undefined;
    try watcher.start(context, io, &receiver, cancelReceiver);
    defer watcher.stop();
    const delivered = try receiver.receive();
    const payload: ?std.json.Value = if (delivered) |value|
        try std.json.parseFromSliceLeaky(std.json.Value, allocator, try std.json.Stringify.valueAlloc(allocator, value, .{}), .{})
    else
        null;
    const result: IReceiveShareTaskResult = .{
        .payload = payload,
    };
    return std.json.parseFromSliceLeaky(std.json.Value, allocator, try std.json.Stringify.valueAlloc(allocator, result, .{}), .{});
}

//
// "find-receiver" background-task handler. Listens for a receiver's UDP broadcast
// for the given share session and returns the discovered endpoint, or null on
// timeout or cancellation.
// (Zig: the task data and output are JSON values holding IFindReceiverTaskData and IFindReceiverTaskResult. The
// sender has no payload to send, which is JSON null.)
//
pub fn findReceiverHandler(allocator: std.mem.Allocator, io: std.Io, taskData: std.json.Value, context: ITaskContext) anyerror!std.json.Value {
    const data = try std.json.parseFromValueLeaky(IFindReceiverTaskData, allocator, taskData, .{
        .ignore_unknown_fields = true,
    });
    var sender = try LanShareSender.init(try lan_share_network.lan_share_types.discoveryPort(), allocator, io, .null, data.code);

    var watcher: CancellationWatcher = undefined;
    try watcher.start(context, io, &sender, cancelSender);
    defer watcher.stop();
    const endpoint = try sender.waitForReceiver(io, SHARE_TIMEOUT_MS);
    const result: IFindReceiverTaskResult = .{
        .endpoint = if (endpoint) |found| .{
            .address = found.address,
            .port = found.port,
            .certFingerprint = found.certFingerprint,
        } else null,
    };
    return std.json.parseFromSliceLeaky(std.json.Value, allocator, try std.json.Stringify.valueAlloc(allocator, result, .{}), .{});
}

//
// "send-payload" background-task handler. Delivers the given payload to a
// previously discovered receiver over HTTPS and reports whether it was accepted.
// (Zig: the task data and output are JSON values holding ISendPayloadTaskData and ISendPayloadTaskResult. The
// handler is given the context every handler is given, and does not use it.)
//
pub fn sendPayloadHandler(allocator: std.mem.Allocator, io: std.Io, taskData: std.json.Value, context: ITaskContext) anyerror!std.json.Value {
    _ = context;
    const data = try std.json.parseFromValueLeaky(ISendPayloadTaskData, allocator, taskData, .{
        .ignore_unknown_fields = true,
    });
    var sender = try LanShareSender.init(try lan_share_network.lan_share_types.discoveryPort(), allocator, io, data.payload, data.code);
    const endpoint: IReceiverEndpoint = .{
        .address = data.endpoint.address,
        .port = data.endpoint.port,
        .certFingerprint = data.endpoint.certFingerprint,
    };
    const success = try sender.send(endpoint);
    const result: ISendPayloadTaskResult = .{
        .success = success,
    };
    return std.json.parseFromSliceLeaky(std.json.Value, allocator, try std.json.Stringify.valueAlloc(allocator, result, .{}), .{});
}
