//
// How a shell hands the core the answer to a host request (see HostRequestFn): the text goes into the buffer the core gave, and the
// number returned is its length, negated when the request failed and the text is the reason.
//

const std = @import("std");

//
// Writes the answer to a host request into the core's buffer and returns what the callback returns. An answer that succeeded but is
// longer than the buffer cannot be handed over, so it is reported as a failure that names the request, and a reason longer than the
// buffer is cut to fit.
//
pub fn writeHostReply(succeeded: bool, method: []const u8, text: []const u8, buffer: [*]u8, capacity: usize) isize {
    if (succeeded and text.len <= capacity) {
        @memcpy(buffer[0..text.len], text);
        return @intCast(text.len);
    }
    if (succeeded) {
        const reason = std.fmt.bufPrint(buffer[0..capacity], "The answer to {s} is too long for the core to take.", .{method}) catch {
            return -@as(isize, @intCast(capacity));
        };
        return -@as(isize, @intCast(reason.len));
    }
    const length = @min(text.len, capacity);
    @memcpy(buffer[0..length], text[0..length]);
    return -@as(isize, @intCast(length));
}
