const std = @import("std");

//
// A progress callback that records every message (for tests). The callbacks run on the thread of the operation that reports
// progress, which is the test's own thread.
//
pub const ProgressRecorder = struct {
    // Allocates the copies of the messages.
    allocator: std.mem.Allocator,

    // The recorded messages.
    messages: std.ArrayList([]const u8) = .empty,

    //
    // Records a message.
    //
    pub fn record(self: *ProgressRecorder, message: []const u8) void {
        const copy = self.allocator.dupe(u8, message) catch {
            return;
        };
        self.messages.append(self.allocator, copy) catch {};
    }
};
