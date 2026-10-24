const std = @import("std");
const lan_share = @import("lan-share-network-zig");

const LanShareReceiver = lan_share.lan_share_receiver.LanShareReceiver;

//
// A receive running on a thread of its own, which is the receiver's one thread from then on, while the test makes its requests from
// the test thread. The receiver serves its connections only while it receives.
//
pub const ReceiveThread = struct {
    // The receiver, started and not used by the test thread again until the receive has ended, except to cancel it.
    receiver: *LanShareReceiver,

    // What the receive returned, read once the thread has ended.
    result: anyerror!?std.json.Value = null,

    // The thread.
    thread: std.Thread = undefined,

    // Whether the thread has been joined.
    joined: bool = false,

    //
    // Starts the receive on its thread.
    //
    pub fn start(self: *ReceiveThread) !void {
        self.thread = try std.Thread.spawn(.{}, run, .{self});
    }

    //
    // The receive thread.
    //
    fn run(self: *ReceiveThread) void {
        self.result = self.receiver.receive();
    }

    //
    // Waits for the receive to end and returns what it returned.
    //
    pub fn finish(self: *ReceiveThread) !?std.json.Value {
        self.thread.join();
        self.joined = true;
        return self.result;
    }

    //
    // Cancels the receive, waits for it to end and returns what it returned.
    //
    pub fn cancelAndFinish(self: *ReceiveThread) !?std.json.Value {
        self.receiver.cancel();
        return self.finish();
    }

    //
    // Cancels the receive and waits for it, if the test has not already, so a test that fails part way never frees the receiver
    // under its thread.
    //
    pub fn stop(self: *ReceiveThread) void {
        if (!self.joined) {
            _ = self.cancelAndFinish() catch {};
        }
    }
};
