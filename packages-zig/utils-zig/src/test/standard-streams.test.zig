const std = @import("std");
const builtin = @import("builtin");
const utils = @import("utils-zig");
const standard_streams = utils.standard_streams;
const thread_messages = @import("thread-messages.zig");
const MessageQueue = thread_messages.MessageQueue;
const ThreadAllocator = thread_messages.ThreadAllocator;

//
// How much the writer sends through the pipe: many times the pipe's quota, so the pipe fills and writes
// have to wait for the reader.
//
const PIPE_TEST_BYTE_COUNT: usize = 256 * 1024;

//
// What the slow reader of the pipe test found.
//
const IPipeReaderResult = struct {
    // The number of bytes the reader took out of the pipe before it was closed.
    byteCount: usize = 0,

    // The error the reader hit, if any.
    // The name of the error the reader hit, or "" for none.
    readError: []const u8 = "",
};

//
// What the reader's thread is given: the handle of the pipe's read end, as a number.
//
const IPipeReaderOrder = struct {
    handle: usize,
};

//
// The reader's thread: makes its own allocator and Io, takes its order, waits before reading, then reads the pipe to its end and
// posts how many bytes came through to the test.
//
fn readPipeSlowly(orders: *MessageQueue, results: *MessageQueue) void {
    var thread_allocator: ThreadAllocator = .init;
    defer thread_allocator.deinit();
    var arena_state = std.heap.ArenaAllocator.init(thread_allocator.allocator());
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var threaded: std.Io.Threaded = .init_single_threaded;
    threaded.allocator = thread_allocator.allocator();
    defer threaded.deinit();
    const io = threaded.io();
    const order = thread_messages.take(IPipeReaderOrder, orders, io, arena) catch |err| {
        std.debug.panic("The reader got no order: {s}", .{@errorName(err)});
    };
    const readEnd: std.Io.File = .{
        .handle = @ptrFromInt(order.handle),
        .flags = .{
            .nonblocking = false,
        },
    };

    // Waits so the pipe is full while the writer is still writing.
    utils.sleep.sleep(io, 300) catch {};
    var buffer: [4096]u8 = undefined;
    var fileReader = readEnd.readerStreaming(io, &buffer);
    var result: IPipeReaderResult = .{};
    if (fileReader.interface.discardRemaining()) |byteCount| {
        result.byteCount = byteCount;
    }
    else |err| {
        result.readError = @errorName(err);
    }
    thread_messages.post(results, io, arena, result) catch @panic("out of memory posting the reader's result");
}

test "the standard streams are the process's own handles" {
    try std.testing.expectEqual(std.Io.File.stdin().handle, standard_streams.stdin().handle);
    try std.testing.expectEqual(std.Io.File.stdout().handle, standard_streams.stdout().handle);
    try std.testing.expectEqual(std.Io.File.stderr().handle, standard_streams.stderr().handle);
}

test "a file opened for synchronous I/O keeps the synchronous description" {
    var tmpDir = std.testing.tmpDir(.{});
    defer tmpDir.cleanup();
    const io = std.testing.io;
    const file = try tmpDir.dir.createFile(io, "synchronous.txt", .{});
    defer file.close(io);

    const described = standard_streams.withActualMode(file);

    try std.testing.expectEqual(file.handle, described.handle);
    try std.testing.expect(!described.flags.nonblocking);
}

test "a slow reader of an asynchronous pipe gets every byte written to it" {
    if (builtin.os.tag != .windows) {
        // Asynchronous pipes, the kind an MSYS2 or Cygwin shell hands a native program, exist only on Windows.
        return error.SkipZigTest;
    }

    const windows = std.os.windows;
    const io = std.testing.io;

    // The same kind of pipe an MSYS2 or Cygwin shell gives a native program as its standard output: the
    // program's end is opened for asynchronous I/O. Here the test reads the other end itself.
    const handles = try std.testing.io_instance.windowsCreatePipe(.{
        .server = .{
            .mode = .{
                .IO = .SYNCHRONOUS_NONALERT,
            },
        },
        .client = .{
            .mode = .{
                .IO = .ASYNCHRONOUS,
            },
        },
        .inbound = true,
    });
    const readEnd: std.Io.File = .{
        .handle = handles[0],
        .flags = .{
            .nonblocking = false,
        },
    };
    defer readEnd.close(io);

    // Described the way std.Io.File.stdout() describes every standard handle, then corrected.
    const writeEnd = standard_streams.withActualMode(.{
        .handle = handles[1],
        .flags = .{
            .nonblocking = false,
        },
    });
    try std.testing.expect(writeEnd.flags.nonblocking);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var orders = MessageQueue.init();
    defer orders.deinit();
    var results = MessageQueue.init();
    defer results.deinit();
    try thread_messages.post(&orders, io, arena.allocator(), IPipeReaderOrder{
        .handle = @intFromPtr(readEnd.handle),
    });
    const reader = try std.Thread.spawn(.{}, readPipeSlowly, .{
        &orders,
        &results,
    });

    const payload = try std.testing.allocator.alloc(u8, PIPE_TEST_BYTE_COUNT);
    defer std.testing.allocator.free(payload);
    @memset(payload, 'x');
    var buffer: [1024]u8 = undefined;
    var fileWriter = writeEnd.writerStreaming(io, &buffer);
    const writeResult = fileWriter.interface.writeAll(payload);
    const flushResult = fileWriter.interface.flush();
    windows.CloseHandle(writeEnd.handle);
    reader.join();
    const result = try thread_messages.take(IPipeReaderResult, &results, io, arena.allocator());

    try writeResult;
    try flushResult;
    try std.testing.expectEqualStrings("", result.readError);
    try std.testing.expectEqual(PIPE_TEST_BYTE_COUNT, result.byteCount);
}
