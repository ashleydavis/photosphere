//
// Tests for S3RangeReadableStream (port of src/tests/s3-range-readable-stream.test.ts).
//

const std = @import("std");
const storage_zig = @import("storage-zig");
const utils = @import("utils-zig");
const helpers = @import("test-helpers.zig");

const s3_client = storage_zig.s3_client;
const S3Client = s3_client.S3Client;
const S3Command = s3_client.S3Command;
const S3CommandOutput = s3_client.S3CommandOutput;
const S3RangeReadableStream = storage_zig.s3_range_readable_stream.S3RangeReadableStream;

//
// The three chunk sizes the stream attempts, in order: 100 MB, 20 MB, 10 MB.
//
const CHUNK_SIZE_LARGE = 100 * 1024 * 1024;
const CHUNK_SIZE_MEDIUM = 20 * 1024 * 1024;
const CHUNK_SIZE_SMALL = 10 * 1024 * 1024;

//
// The first and last byte of a Range header such as "bytes=0-99".
//
const IRange = struct {
    // The first byte.
    start: u64,

    // The last byte.
    end: u64,
};

//
// Reads the first and last byte out of a Range header (TypeScript: `rangeHeader.match(/bytes=(\d+)-(\d+)/)`).
//
fn parseRange(rangeHeader: []const u8) !IRange {
    const prefix = "bytes=";
    if (!std.mem.startsWith(u8, rangeHeader, prefix)) {
        return s3_client.throwServiceException("Error", "Invalid Range header", 0);
    }
    const dash = std.mem.indexOfScalar(u8, rangeHeader, '-') orelse return s3_client.throwServiceException("Error", "Invalid Range header", 0);
    return .{
        .start = try std.fmt.parseInt(u64, rangeHeader[prefix.len..dash], 10),
        .end = try std.fmt.parseInt(u64, rangeHeader[dash + 1 ..], 10),
    };
}

//
// Answers a GetObjectCommand for a test (the TypeScript tests' mockImplementation).
//
const Answer = *const fn (mock: *MockS3, range: IRange) anyerror!S3CommandOutput;

//
// An S3 client whose send() answers each GetObjectCommand from a function, recording the Range of every
// request (TypeScript: `{ send: jest.fn()... } as S3Client`).
//
const MockS3 = struct {
    // Allocates the recorded ranges and the answers.
    allocator: std.mem.Allocator,

    // The data of the object.
    data: []u8,

    // Answers each command.
    answer: Answer,

    // The Range of every request sent, in order (TypeScript: `mockSend.mock.calls[n][0].input.Range`).
    ranges: std.ArrayList([]const u8),

    // The client whose send() this replaces.
    s3: S3Client,

    //
    // Creates the client for the data.
    //
    fn init(mock: *MockS3, allocator: std.mem.Allocator, data: []u8, answer: Answer) void {
        mock.* = .{
            .allocator = allocator,
            .data = data,
            .answer = answer,
            .ranges = .empty,
            .s3 = S3Client.init(std.testing.io, .{ .endpoint = null, .region = null, .credentials = null }),
        };
        mock.s3.send = .{ .context = mock, .function = send };
    }

    //
    // Shuts the client down.
    //
    fn deinit(mock: *MockS3) void {
        mock.s3.deinit();
    }

    //
    // Records the request's Range and answers it.
    //
    fn send(context: *anyopaque, command: S3Command) anyerror!S3CommandOutput {
        const mock: *MockS3 = @ptrCast(@alignCast(context));
        const rangeHeader = command.GetObjectCommand.Range.?;
        try mock.ranges.append(mock.allocator, try mock.allocator.dupe(u8, rangeHeader));
        return mock.answer(mock, try parseRange(rangeHeader));
    }

    //
    // How many requests were sent (TypeScript: `mockSend` toHaveBeenCalledTimes).
    //
    fn callCount(mock: *const MockS3) usize {
        return mock.ranges.items.len;
    }

    //
    // Creates a stream over the mock client.
    //
    fn stream(mock: *MockS3) !*S3RangeReadableStream {
        return S3RangeReadableStream.init(mock.allocator, std.testing.io, &mock.s3, "my-bucket", "my-key");
    }
};

//
// Builds a mock S3 range response for a slice of data.
//
fn makeRangeResponse(allocator: std.mem.Allocator, slice: []u8, totalSize: u64, rangeStart: u64) !S3CommandOutput {
    const rangeEnd = rangeStart + slice.len - 1;
    return .{ .GetObject = .{
        .ContentRange = try std.fmt.allocPrint(allocator, "bytes {d}-{d}/{d}", .{ rangeStart, rangeEnd, totalSize }),
        .Body = slice,
    } };
}

//
// Answers with the slice of the data the Range asks for (TypeScript: makeMockS3).
//
fn sliceAnswer(mock: *MockS3, range: IRange) anyerror!S3CommandOutput {
    if (range.start >= mock.data.len) {
        return s3_client.throwServiceException("NoSuchKey", "NoSuchKey", 0);
    }
    const end = @min(range.end, mock.data.len - 1);
    return makeRangeResponse(mock.allocator, mock.data[range.start .. end + 1], mock.data.len, range.start);
}

//
// Collects a stream into a single buffer (TypeScript: streamToBuffer).
//
fn streamToBuffer(allocator: std.mem.Allocator, rangeStream: *S3RangeReadableStream) ![]u8 {
    return helpers.readAll(allocator, rangeStream.reader());
}

//
// Keeps the retried attempts' warnings (retry's "Retrying after" line) out of the test output.
//
fn captureStderr(allocator: std.mem.Allocator) *std.Io.Writer.Allocating {
    const captured = allocator.create(std.Io.Writer.Allocating) catch unreachable;
    captured.* = .init(allocator);
    utils.console.setCapture(null, &captured.writer);
    return captured;
}

// describe("S3RangeReadableStream")

test "reads a small file in a single chunk" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var mock: MockS3 = undefined;
    mock.init(arena.allocator(), try arena.allocator().dupe(u8, "hello world"), sliceAnswer);
    defer mock.deinit();
    const rangeStream = try mock.stream();
    defer rangeStream.destroy(std.testing.io);
    const result = try streamToBuffer(arena.allocator(), rangeStream);
    try std.testing.expectEqualStrings("hello world", result);
    try std.testing.expectEqual(@as(usize, 1), mock.callCount());
}

//
// Answers with the slice of the data but no ContentRange, so the stream cannot learn the file size.
//
fn noContentRangeAnswer(mock: *MockS3, range: IRange) anyerror!S3CommandOutput {
    const end = @min(range.end, mock.data.len - 1);
    return .{ .GetObject = .{ .ContentRange = null, .Body = mock.data[range.start .. end + 1] } };
}

test "ends the stream on a short read when the response carries no Content-Range" {
    // The file size is normally learned from Content-Range. It is not always available: on the
    // mobile worker the response reaches the SDK through the native HTTP bridge without it. A
    // range that comes back shorter than it asked for is then the only signal that the end of the
    // object has been reached, and without acting on it the stream requests ranges for ever and
    // never ends, which hung every read from S3 on a device until its caller timed out.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var mock: MockS3 = undefined;
    mock.init(arena.allocator(), try arena.allocator().dupe(u8, "a short object with no content range"), noContentRangeAnswer);
    defer mock.deinit();

    const rangeStream = try mock.stream();
    defer rangeStream.destroy(std.testing.io);
    const result = try streamToBuffer(arena.allocator(), rangeStream);

    try std.testing.expectEqualStrings("a short object with no content range", result);
    try std.testing.expectEqual(@as(usize, 1), mock.callCount());
}

//
// Answers every request with an empty object.
//
fn emptyAnswer(mock: *MockS3, range: IRange) anyerror!S3CommandOutput {
    _ = range;
    return .{ .GetObject = .{ .ContentRange = "bytes 0-0/0", .Body = try mock.allocator.alloc(u8, 0) } };
}

test "reads an empty file" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var mock: MockS3 = undefined;
    mock.init(arena.allocator(), &.{}, emptyAnswer);
    defer mock.deinit();
    const rangeStream = try mock.stream();
    defer rangeStream.destroy(std.testing.io);
    const result = try streamToBuffer(arena.allocator(), rangeStream);
    try std.testing.expectEqual(@as(usize, 0), result.len);
}

//
// Rejects every request with a ServiceUnavailable error.
//
fn unavailableAnswer(mock: *MockS3, range: IRange) anyerror!S3CommandOutput {
    _ = mock;
    _ = range;
    return s3_client.throwServiceException("ServiceUnavailable", "S3 unavailable", 0);
}

test "emits an error when all chunk sizes fail" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var mock: MockS3 = undefined;
    mock.init(arena.allocator(), &.{}, unavailableAnswer);
    defer mock.deinit();
    _ = captureStderr(arena.allocator());
    defer utils.console.setCapture(null, null);
    const rangeStream = try mock.stream();
    defer rangeStream.destroy(std.testing.io);
    try std.testing.expectError(error.ReadFailed, streamToBuffer(arena.allocator(), rangeStream));
    try std.testing.expectEqualStrings("S3 unavailable", utils.errors.lastErrorMessage());
}

//
// Rejects every request with a network failure.
//
fn networkFailureAnswer(mock: *MockS3, range: IRange) anyerror!S3CommandOutput {
    _ = mock;
    _ = range;
    return s3_client.throwServiceException("Error", "network failure", 0);
}

test "tries all three chunk sizes before emitting error" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var mock: MockS3 = undefined;
    mock.init(arena.allocator(), &.{}, networkFailureAnswer);
    defer mock.deinit();
    _ = captureStderr(arena.allocator());
    defer utils.console.setCapture(null, null);
    const rangeStream = try mock.stream();
    defer rangeStream.destroy(std.testing.io);
    try std.testing.expectError(error.ReadFailed, streamToBuffer(arena.allocator(), rangeStream));
    try std.testing.expectEqualStrings("network failure", utils.errors.lastErrorMessage());
    try std.testing.expectEqual(@as(usize, 3), mock.callCount());
}

//
// Rejects a request for a 100 MB chunk and answers smaller ones.
//
fn failLargeAnswer(mock: *MockS3, range: IRange) anyerror!S3CommandOutput {
    if (range.end - range.start >= CHUNK_SIZE_LARGE - 1) {
        return s3_client.throwServiceException("Error", "chunk too large", 0);
    }
    const sliceEnd = @min(range.end, mock.data.len - 1);
    return makeRangeResponse(mock.allocator, mock.data[range.start .. sliceEnd + 1], mock.data.len, range.start);
}

test "falls back to medium chunk size when large chunk fails" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var mock: MockS3 = undefined;
    mock.init(arena.allocator(), try arena.allocator().dupe(u8, "hello world"), failLargeAnswer);
    defer mock.deinit();
    _ = captureStderr(arena.allocator());
    defer utils.console.setCapture(null, null);
    const rangeStream = try mock.stream();
    defer rangeStream.destroy(std.testing.io);
    const result = try streamToBuffer(arena.allocator(), rangeStream);
    try std.testing.expectEqualStrings("hello world", result);
    // First call fails (100 MB), second succeeds (20 MB)
    try std.testing.expectEqual(@as(usize, 2), mock.callCount());
    try std.testing.expectEqualStrings(std.fmt.comptimePrint("bytes=0-{d}", .{CHUNK_SIZE_MEDIUM - 1}), mock.ranges.items[1]);
}

//
// Rejects a request for a 100 MB or 20 MB chunk and answers smaller ones.
//
fn failMediumAnswer(mock: *MockS3, range: IRange) anyerror!S3CommandOutput {
    if (range.end - range.start >= CHUNK_SIZE_MEDIUM - 1) {
        return s3_client.throwServiceException("Error", "chunk failed", 0);
    }
    const sliceEnd = @min(range.end, mock.data.len - 1);
    return makeRangeResponse(mock.allocator, mock.data[range.start .. sliceEnd + 1], mock.data.len, range.start);
}

test "falls back to small chunk size when large and medium chunks fail" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var mock: MockS3 = undefined;
    mock.init(arena.allocator(), try arena.allocator().dupe(u8, "hello world"), failMediumAnswer);
    defer mock.deinit();
    _ = captureStderr(arena.allocator());
    defer utils.console.setCapture(null, null);
    const rangeStream = try mock.stream();
    defer rangeStream.destroy(std.testing.io);
    const result = try streamToBuffer(arena.allocator(), rangeStream);
    try std.testing.expectEqualStrings("hello world", result);
    // First two calls fail (100 MB, 20 MB), third succeeds (10 MB)
    try std.testing.expectEqual(@as(usize, 3), mock.callCount());
    try std.testing.expectEqualStrings(std.fmt.comptimePrint("bytes=0-{d}", .{CHUNK_SIZE_SMALL - 1}), mock.ranges.items[2]);
}

//
// Rejects only the very first request (100 MB chunk).
//
fn failFirstAnswer(mock: *MockS3, range: IRange) anyerror!S3CommandOutput {
    if (mock.callCount() == 1) {
        return s3_client.throwServiceException("Error", "first chunk failed", 0);
    }
    const sliceEnd = @min(range.end, mock.data.len - 1);
    return makeRangeResponse(mock.allocator, mock.data[range.start .. sliceEnd + 1], mock.data.len, range.start);
}

test "uses the smaller chunk size for all subsequent chunks after a fallback" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const data = try arena.allocator().alloc(u8, 25);
    @memset(data, 0xaa);
    var mock: MockS3 = undefined;
    mock.init(arena.allocator(), data, failFirstAnswer);
    defer mock.deinit();
    _ = captureStderr(arena.allocator());
    defer utils.console.setCapture(null, null);
    const rangeStream = try mock.stream();
    defer rangeStream.destroy(std.testing.io);
    const result = try streamToBuffer(arena.allocator(), rangeStream);
    try std.testing.expectEqualSlices(u8, data, result);
    // 1 failed large + 1 medium chunk that covers the whole 25-byte file
    try std.testing.expectEqual(@as(usize, 2), mock.callCount());
    try std.testing.expectEqualStrings(std.fmt.comptimePrint("bytes=0-{d}", .{CHUNK_SIZE_MEDIUM - 1}), mock.ranges.items[1]);
}

test "does not make additional requests after being destroyed" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const data = try arena.allocator().alloc(u8, 200 * 1024 * 1024); // 200 MB, spans two 100 MB chunks
    @memset(data, 0xff);
    var mock: MockS3 = undefined;
    mock.init(arena.allocator(), data, sliceAnswer);
    defer mock.deinit();
    const rangeStream = try mock.stream();

    _ = try rangeStream.reader().takeByte();
    rangeStream.destroy(std.testing.io);

    const callsAfterDestroy = mock.callCount();
    try std.Io.sleep(std.testing.io, .fromMilliseconds(20), .awake);
    try std.testing.expectEqual(callsAfterDestroy, mock.callCount());
}

//
// Answers every request with a Content-Range but no body.
//
fn missingBodyAnswer(mock: *MockS3, range: IRange) anyerror!S3CommandOutput {
    _ = mock;
    _ = range;
    return .{ .GetObject = .{ .ContentRange = "bytes 0-9/10", .Body = null } };
}

test "handles missing Body in response gracefully" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var mock: MockS3 = undefined;
    mock.init(arena.allocator(), &.{}, missingBodyAnswer);
    defer mock.deinit();
    const rangeStream = try mock.stream();
    defer rangeStream.destroy(std.testing.io);
    const result = try streamToBuffer(arena.allocator(), rangeStream);
    try std.testing.expectEqual(@as(usize, 0), result.len);
}
