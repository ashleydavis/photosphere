const std = @import("std");
const utils = @import("utils-zig");
const timestamp_provider = utils.timestamp_provider;

//
// Deterministic timestamp provider for tests: starts at a fixed time and advances by one millisecond per call.
//
pub const TestTimestampProvider = struct {
    // 2022-01-01T00:00:00.000Z
    const FIXED_TIMESTAMP: i64 = 1640995200000;

    // Number of timestamps handed out so far.
    counter: i64 = 0,

    //
    // Gets the ITimestampProvider interface for this provider.
    //
    pub fn timestampProvider(self: *TestTimestampProvider) timestamp_provider.ITimestampProvider {
        return .{ .ptr = self, .vtable = &vtable };
    }

    //
    // The ITimestampProvider functions of this provider.
    //
    const vtable: timestamp_provider.ITimestampProvider.VTable = .{
        .now = nowErased,
        .dateNow = dateNowErased,
    };

    //
    // Returns the fixed timestamp plus the number of previous calls.
    //
    pub fn now(self: *TestTimestampProvider) i64 {
        const timestamp = FIXED_TIMESTAMP + self.counter;
        self.counter += 1;
        return timestamp;
    }

    //
    // Returns now() as a Date.
    //
    pub fn dateNow(self: *TestTimestampProvider) timestamp_provider.Date {
        return .{ .epochMilliseconds = self.now() };
    }

    //
    // Restarts the counter.
    //
    pub fn reset(self: *TestTimestampProvider) void {
        self.counter = 0;
    }

    //
    // Type-erased now for the vtable.
    //
    fn nowErased(ptr: *anyopaque, io: std.Io) i64 {
        _ = io;
        const self: *TestTimestampProvider = @ptrCast(@alignCast(ptr));
        return self.now();
    }

    //
    // Type-erased dateNow for the vtable.
    //
    fn dateNowErased(ptr: *anyopaque, io: std.Io) timestamp_provider.Date {
        _ = io;
        const self: *TestTimestampProvider = @ptrCast(@alignCast(ptr));
        return self.dateNow();
    }
};
