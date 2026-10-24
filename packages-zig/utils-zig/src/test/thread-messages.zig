//
// How a test talks to a thread it starts. The thread is given copies of what it needs as JSON on a message queue and posts what it
// found back the same way, so the test and its threads share nothing but the queues. Each side posts and takes with its own Io and
// its own allocator: a thread makes them when it starts (a ThreadAllocator and a std.Io.Threaded of its own).
//
const std = @import("std");
const ziggy = @import("ziggy");

pub const MessageQueue = ziggy.message_queue.MessageQueue;
pub const ThreadAllocator = ziggy.thread_allocator.ThreadAllocator;

//
// How long a take waits for a message before the test fails, in seconds.
//
pub const TAKE_SECONDS = 10;

//
// Posts the value to the queue as JSON text, with the Io and allocator of the calling thread.
//
pub fn post(queue: *MessageQueue, io: std.Io, allocator: std.mem.Allocator, value: anytype) !void {
    const text = try std.json.Stringify.valueAlloc(allocator, value, .{});
    defer allocator.free(text);
    try queue.post(io, 0, text);
}

//
// Takes the next message from the queue, waiting up to TAKE_SECONDS, and parses it as a T in the arena of the calling thread.
// error.NoMessage when none came in time, or when the queue is closed and empty.
//
pub fn take(comptime T: type, queue: *MessageQueue, io: std.Io, arena: std.mem.Allocator) !T {
    const message = queue.take(io, arena, .{
        .duration = .{
            .raw = .fromSeconds(TAKE_SECONDS),
            .clock = .awake,
        },
    }) orelse {
        return error.NoMessage;
    };
    return parse(T, arena, message.text);
}

//
// Takes the next message from the queue without waiting and parses it as a T in the arena of the calling thread, or returns null
// when there is none.
//
pub fn tryTake(comptime T: type, queue: *MessageQueue, io: std.Io, arena: std.mem.Allocator) !?T {
    const message = queue.tryTake(io, arena) orelse {
        return null;
    };
    return try parse(T, arena, message.text);
}

//
// Parses the text of a message as a T in the arena.
//
fn parse(comptime T: type, arena: std.mem.Allocator, text: []const u8) !T {
    return std.json.parseFromSliceLeaky(T, arena, text, .{
        .allocate = .alloc_always,
    });
}
