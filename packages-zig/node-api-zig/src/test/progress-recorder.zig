const std = @import("std");

//
// A progress callback that records every message (for tests).
//
pub const ProgressRecorder = struct {
    // Allocates the copies of the messages.
    allocator: std.mem.Allocator,

    // The recorded messages.
    messages: std.ArrayList([]const u8) = .empty,

    // Guards messages (callbacks may run on other threads).
    mutex: std.Io.Mutex = .init,

    //
    // Records a message.
    //
    pub fn record(self: *ProgressRecorder, message: []const u8) void {
        while (!self.mutex.tryLock()) {
            std.atomic.spinLoopHint();
        }
        defer self.mutex.state.store(.unlocked, .release);
        const copy = self.allocator.dupe(u8, message) catch {
            return;
        };
        self.messages.append(self.allocator, copy) catch {};
    }
};
