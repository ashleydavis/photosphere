const std = @import("std");
const storage_zig = @import("storage-zig");
const utils = @import("utils-zig");
const helpers = @import("test-helpers.zig");
const mock = @import("mock-s3-server.zig");
const MockS3Server = mock.MockS3Server;

const S3Client = storage_zig.s3_client.S3Client;
const S3RangeReadableStream = storage_zig.s3_range_readable_stream.S3RangeReadableStream;

//
// The three chunk sizes the stream attempts, in order: 100 MB, 20 MB, 10 MB.
//
const CHUNK_SIZE_LARGE = 100 * 1024 * 1024;
const CHUNK_SIZE_MEDIUM = 20 * 1024 * 1024;
const CHUNK_SIZE_SMALL = 10 * 1024 * 1024;

//
// A mock server and a client connected to it (TypeScript: the mocked S3Client).
//
const Fixture = struct {
    // The arena for the test.
    arena: std.heap.ArenaAllocator,

    // The mock server.
    server: *MockS3Server,

    // The client.
    s3: S3Client,

    //
    // Starts the server and creates the client.
    //
    fn init(fixture: *Fixture) !void {
        fixture.arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        fixture.server = try MockS3Server.start(std.testing.io);
        fixture.s3 = S3Client.init(std.testing.io, .{
            .endpoint = try fixture.server.endpoint(fixture.arena.allocator()),
            .region = mock.REGION,
            .credentials = .{ .accessKeyId = mock.ACCESS_KEY_ID, .secretAccessKey = mock.SECRET_ACCESS_KEY, .sessionToken = null },
        });
    }

    //
    // Stops everything.
    //
    fn deinit(fixture: *Fixture) void {
        fixture.s3.deinit();
        fixture.server.stop();
        fixture.arena.deinit();
    }

    //
    // Creates a stream for an object of the mock server.
    //
    fn stream(fixture: *Fixture, key: []const u8) !*S3RangeReadableStream {
        return S3RangeReadableStream.init(fixture.arena.allocator(), std.testing.io, &fixture.s3, "my-bucket", key);
    }

    //
    // Collects a stream into a single buffer (TypeScript: streamToBuffer).
    //
    fn streamToBuffer(fixture: *Fixture, rangeStream: *S3RangeReadableStream) ![]u8 {
        return helpers.readAll(fixture.arena.allocator(), rangeStream.reader());
    }
};

// describe("S3RangeReadableStream")

test "reads a small file in a single chunk" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    try fixture.server.putObject("my-bucket/my-key", "hello world");
    const rangeStream = try fixture.stream("my-key");
    defer rangeStream.destroy(std.testing.io);
    const result = try fixture.streamToBuffer(rangeStream);
    try std.testing.expectEqualStrings("hello world", result);
    try std.testing.expectEqual(@as(usize, 1), fixture.server.countRequests("GET"));
}

test "ends the stream on a short read when the response carries no Content-Range" {
    // The file size is normally learned from Content-Range. It is not always available: on the
    // mobile worker the response reaches the SDK through the native HTTP bridge without it. A
    // range that comes back shorter than it asked for is then the only signal that the end of the
    // object has been reached, and without acting on it the stream requests ranges for ever and
    // never ends, which hung every read from S3 on a device until its caller timed out.
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    try fixture.server.putObject("my-bucket/my-key", "a short object with no content range");

    // No ContentRange, so the stream cannot learn the file size.
    fixture.server.omitContentRange = true;

    const rangeStream = try fixture.stream("my-key");
    defer rangeStream.destroy(std.testing.io);
    const result = try fixture.streamToBuffer(rangeStream);

    try std.testing.expectEqualStrings("a short object with no content range", result);
    try std.testing.expectEqual(@as(usize, 1), fixture.server.countRequests("GET"));
}

test "reads an empty file" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    try fixture.server.putObject("my-bucket/my-key", "");
    const rangeStream = try fixture.stream("my-key");
    defer rangeStream.destroy(std.testing.io);
    const result = try fixture.streamToBuffer(rangeStream);
    try std.testing.expectEqual(@as(usize, 0), result.len);
}

test "emits an error when all chunk sizes fail" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    try fixture.server.putObject("my-bucket/my-key", "hello world");
    fixture.server.getObjectUnavailableMessage = "S3 unavailable";
    var capturedStderr: std.Io.Writer.Allocating = .init(fixture.arena.allocator());
    utils.console.setCapture(null, &capturedStderr.writer);
    defer utils.console.setCapture(null, null);
    const rangeStream = try fixture.stream("my-key");
    defer rangeStream.destroy(std.testing.io);
    try std.testing.expectError(error.ReadFailed, fixture.streamToBuffer(rangeStream));
    // The SDK reports a 503 response as its AWS_ERROR_S3_SLOW_DOWN error (it keeps the S3 error body only for errors
    // it does not retry).
    try std.testing.expectEqualStrings("An operation failed. Retrying after: Response code indicates throttling\nAn operation failed. Retrying after: Response code indicates throttling\nOperation failed, no more retries allowed. Last error: Error: Response code indicates throttling\n", capturedStderr.written());
    try std.testing.expectEqual(@as(?anyerror, error.Thrown), rangeStream.err);
    try std.testing.expectEqualStrings("Response code indicates throttling", utils.errors.lastErrorMessage());
    try std.testing.expectEqualStrings("AWS_ERROR_S3_SLOW_DOWN", utils.errors.lastErrorName());
}

test "tries all three chunk sizes before emitting error" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    try fixture.server.putObject("my-bucket/my-key", "hello world");
    fixture.server.dropGetObjectConnections = true;
    var capturedStderr: std.Io.Writer.Allocating = .init(fixture.arena.allocator());
    utils.console.setCapture(null, &capturedStderr.writer);
    defer utils.console.setCapture(null, null);
    const rangeStream = try fixture.stream("my-key");
    defer rangeStream.destroy(std.testing.io);
    try std.testing.expectError(error.ReadFailed, fixture.streamToBuffer(rangeStream));
    try std.testing.expectEqualStrings("An operation failed. Retrying after: socket is closed.\nAn operation failed. Retrying after: socket is closed.\nOperation failed, no more retries allowed. Last error: Error: socket is closed.\n", capturedStderr.written());
    try std.testing.expectEqualStrings("socket is closed.", utils.errors.lastErrorMessage());
    try std.testing.expectEqualStrings("AWS_IO_SOCKET_CLOSED", utils.errors.lastErrorName());
    const ranges = try fixture.server.recordedRanges(fixture.arena.allocator());
    try std.testing.expectEqual(@as(usize, 3), ranges.len);
    try std.testing.expectEqualStrings(std.fmt.comptimePrint("bytes=0-{d}", .{CHUNK_SIZE_LARGE - 1}), ranges[0]);
    try std.testing.expectEqualStrings(std.fmt.comptimePrint("bytes=0-{d}", .{CHUNK_SIZE_MEDIUM - 1}), ranges[1]);
    try std.testing.expectEqualStrings(std.fmt.comptimePrint("bytes=0-{d}", .{CHUNK_SIZE_SMALL - 1}), ranges[2]);
}

test "falls back to medium chunk size when large chunk fails" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    try fixture.server.putObject("my-bucket/my-key", "hello world");
    fixture.server.failRangesOfAtLeast = CHUNK_SIZE_LARGE;

    // The retried attempts warn on stderr (retry's "Retrying after" line); captured to keep the test output clean.
    var capturedStderr: std.Io.Writer.Allocating = .init(fixture.arena.allocator());
    utils.console.setCapture(null, &capturedStderr.writer);
    defer utils.console.setCapture(null, null);
    const rangeStream = try fixture.stream("my-key");
    defer rangeStream.destroy(std.testing.io);
    const result = try fixture.streamToBuffer(rangeStream);
    try std.testing.expectEqualStrings("hello world", result);
    // First call fails (100 MB), second succeeds (20 MB)
    const ranges = try fixture.server.recordedRanges(fixture.arena.allocator());
    try std.testing.expectEqual(@as(usize, 2), ranges.len);
    try std.testing.expectEqualStrings(std.fmt.comptimePrint("bytes=0-{d}", .{CHUNK_SIZE_MEDIUM - 1}), ranges[1]);
}

test "falls back to small chunk size when large and medium chunks fail" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    try fixture.server.putObject("my-bucket/my-key", "hello world");
    fixture.server.failRangesOfAtLeast = CHUNK_SIZE_MEDIUM;

    // The retried attempts warn on stderr (retry's "Retrying after" line); captured to keep the test output clean.
    var capturedStderr: std.Io.Writer.Allocating = .init(fixture.arena.allocator());
    utils.console.setCapture(null, &capturedStderr.writer);
    defer utils.console.setCapture(null, null);
    const rangeStream = try fixture.stream("my-key");
    defer rangeStream.destroy(std.testing.io);
    const result = try fixture.streamToBuffer(rangeStream);
    try std.testing.expectEqualStrings("hello world", result);
    // First two calls fail (100 MB, 20 MB), third succeeds (10 MB)
    const ranges = try fixture.server.recordedRanges(fixture.arena.allocator());
    try std.testing.expectEqual(@as(usize, 3), ranges.len);
    try std.testing.expectEqualStrings(std.fmt.comptimePrint("bytes=0-{d}", .{CHUNK_SIZE_SMALL - 1}), ranges[2]);
}

test "uses the smaller chunk size for all subsequent chunks after a fallback" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const data = [_]u8{0xaa} ** 25;
    try fixture.server.putObject("my-bucket/my-key", &data);
    // Only fail the very first request (100 MB chunk)
    fixture.server.failGetObjectCount = 1;

    // The retried attempts warn on stderr (retry's "Retrying after" line); captured to keep the test output clean.
    var capturedStderr: std.Io.Writer.Allocating = .init(fixture.arena.allocator());
    utils.console.setCapture(null, &capturedStderr.writer);
    defer utils.console.setCapture(null, null);
    const rangeStream = try fixture.stream("my-key");
    defer rangeStream.destroy(std.testing.io);
    const result = try fixture.streamToBuffer(rangeStream);
    try std.testing.expectEqualSlices(u8, &data, result);
    // 1 failed large + 1 medium chunk that covers the whole 25-byte file
    const ranges = try fixture.server.recordedRanges(fixture.arena.allocator());
    try std.testing.expectEqual(@as(usize, 2), ranges.len);
    try std.testing.expectEqualStrings(std.fmt.comptimePrint("bytes=0-{d}", .{CHUNK_SIZE_MEDIUM - 1}), ranges[1]);
    try std.testing.expectEqual(@as(usize, 1), rangeStream.chunkSizeIndex);
}

test "reads a file that spans several chunks" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const size = CHUNK_SIZE_MEDIUM + 1234;
    try fixture.server.putSyntheticObject("my-bucket/my-key", size, 0x5a);
    // Force 20 MB chunks so the file needs two range requests.
    fixture.server.failGetObjectCount = 1;

    // The retried attempts warn on stderr (retry's "Retrying after" line); captured to keep the test output clean.
    var capturedStderr: std.Io.Writer.Allocating = .init(fixture.arena.allocator());
    utils.console.setCapture(null, &capturedStderr.writer);
    defer utils.console.setCapture(null, null);
    const rangeStream = try fixture.stream("my-key");
    defer rangeStream.destroy(std.testing.io);
    const result = try fixture.streamToBuffer(rangeStream);
    try std.testing.expectEqual(@as(usize, size), result.len);
    try std.testing.expect(std.mem.allEqual(u8, result, 0x5a));
    const ranges = try fixture.server.recordedRanges(fixture.arena.allocator());
    try std.testing.expectEqual(@as(usize, 3), ranges.len);
    try std.testing.expectEqualStrings(std.fmt.comptimePrint("bytes={d}-{d}", .{ CHUNK_SIZE_MEDIUM, 2 * CHUNK_SIZE_MEDIUM - 1 }), ranges[2]);
}

test "does not make additional requests after being destroyed" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    // Larger than one 100 MB chunk, so reading everything would take two requests.
    try fixture.server.putSyntheticObject("my-bucket/my-key", CHUNK_SIZE_LARGE + 10, 0xff);
    const rangeStream = try fixture.stream("my-key");
    const firstByte = try rangeStream.reader().takeByte();
    try std.testing.expectEqual(@as(u8, 0xff), firstByte);
    rangeStream.destroy(std.testing.io);
    const callsAfterDestroy = fixture.server.countRequests("GET");
    try std.testing.expectEqual(@as(usize, 1), callsAfterDestroy);
    try std.Io.sleep(std.testing.io, .fromMilliseconds(20), .awake);
    try std.testing.expectEqual(callsAfterDestroy, fixture.server.countRequests("GET"));
}

test "handles missing Body in response gracefully" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    // The mock answers "no-body" with Content-Range "bytes 0-9/10" and an empty body.
    const rangeStream = try fixture.stream("no-body");
    defer rangeStream.destroy(std.testing.io);
    const result = try fixture.streamToBuffer(rangeStream);
    try std.testing.expectEqual(@as(usize, 0), result.len);
}
