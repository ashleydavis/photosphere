const std = @import("std");
const ILog = @import("utils-zig").log.ILog;
const Timers = @import("ziggy").timers.Timers;
const task_queue_zig = @import("ziggy").task_queue;
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
// How often (in milliseconds) the sender's wait looks at the task context for cancellation. The share runs on the task's own thread,
// in slices, and the task looks between them.
//
const CANCEL_POLL_INTERVAL_MS = 250;

//
// "receive-share" background-task handler. Hosts a LAN receiver advertising the
// supplied pairing code and waits for a sender to deliver a payload.
// Returns the delivered payload, or null on timeout or cancellation.
// (Zig: the task data and output are JSON values holding IReceiveShareTaskData and IReceiveShareTaskResult. The
// receiver is deinitialised when the handler returns, which frees the payload it holds, so the payload is copied
// with the task's allocator first.)
//
pub fn receiveShareHandler(allocator: std.mem.Allocator, io: std.Io, _: Timers, log: ILog, taskData: std.json.Value, context: ITaskContext) anyerror!std.json.Value {
    const data = try std.json.parseFromValueLeaky(IReceiveShareTaskData, allocator, taskData, .{
        .ignore_unknown_fields = true,
    });
    var receiver = LanShareReceiver.init(try lan_share_network.lan_share_types.discoveryPort(), io, SHARE_TIMEOUT_MS);
    defer receiver.deinit();
    try receiver.start(data.code);

    // The receive runs in slices, each waiting a short time for a connection (see receiveStep), with a look for cancellation between
    // them. A connection being served is served to its end first.
    while (receiver.receiveStep(log)) {
        if (context.isCancelled(io, allocator)) {
            receiver.cancel();
        }
    }
    const delivered = receiver.finishReceive();
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
pub fn findReceiverHandler(allocator: std.mem.Allocator, io: std.Io, _: Timers, log: ILog, taskData: std.json.Value, context: ITaskContext) anyerror!std.json.Value {
    _ = log;
    const data = try std.json.parseFromValueLeaky(IFindReceiverTaskData, allocator, taskData, .{
        .ignore_unknown_fields = true,
    });
    var sender = try LanShareSender.init(try lan_share_network.lan_share_types.discoveryPort(), allocator, io, .null, data.code);

    // The wait runs in slices of CANCEL_POLL_INTERVAL_MS, with a look for cancellation between them. A receiver announces itself
    // every second, so one that announced between two slices is heard at its next announcement.
    const deadline = std.Io.Clock.awake.now(io).toMilliseconds() + SHARE_TIMEOUT_MS;
    var endpoint: ?IReceiverEndpoint = null;
    while (endpoint == null and !context.isCancelled(io, allocator)) {
        const remaining = deadline - std.Io.Clock.awake.now(io).toMilliseconds();
        if (remaining <= 0) {
            break;
        }
        endpoint = try sender.waitForReceiver(io, @min(remaining, CANCEL_POLL_INTERVAL_MS));
    }
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
pub fn sendPayloadHandler(allocator: std.mem.Allocator, io: std.Io, _: Timers, log: ILog, taskData: std.json.Value, context: ITaskContext) anyerror!std.json.Value {
    _ = log;
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
