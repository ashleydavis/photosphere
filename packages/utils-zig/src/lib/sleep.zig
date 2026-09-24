const std = @import("std");

//
// Sleeps for the specified millseconds.
//
pub fn sleep(io: std.Io, timeMS: u64) !void {
    try io.sleep(.fromMilliseconds(@intCast(timeMS)), .awake);
}
