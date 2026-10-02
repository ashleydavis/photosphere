//
// Tests for the CloudStorage operations that have no unit test of their own: read, write, readStream, deleteFile,
// deleteDir, copyTo, checkWriteLock, listFiles, listDirs, fileExists, dirExists and isEmpty. They run against a
// client whose `send` is replaced, so no S3 server is needed; the integration tests cover the same operations
// against a real one.
//

const std = @import("std");
const storage_zig = @import("storage-zig");
const utils = @import("utils-zig");

const CloudStorage = storage_zig.cloud_storage.CloudStorage;
const s3_client = storage_zig.s3_client;
const S3Command = s3_client.S3Command;
const S3CommandOutput = s3_client.S3CommandOutput;

//
// Answers a command for a test (the handler of cloud-storage-write-stream-hashed.test.zig).
//
const Handler = *const fn (command: S3Command) anyerror!S3CommandOutput;

//
// An S3 client that answers each command from a function, recording every command it was sent. The client
// `send` seam is the one the write-stream-hashed tests use, so nothing here needs a server.
//
const FakeClient = struct {
    // Allocates the recorded commands.
    allocator: std.mem.Allocator,

    // Every command the storage sent, in order.
    commands: std.ArrayList(S3Command),

    // Answers each command.
    handler: Handler,

    //
    // Records the command and answers it with the handler.
    //
    fn send(context: *anyopaque, command: S3Command) anyerror!S3CommandOutput {
        const client: *FakeClient = @ptrCast(@alignCast(context));
        try client.commands.append(client.allocator, command);
        return client.handler(command);
    }

    //
    // How many commands of the given kind the storage sent.
    //
    fn countOf(client: *const FakeClient, comptime tag: std.meta.Tag(S3Command)) usize {
        var count: usize = 0;
        for (client.commands.items) |command| {
            if (std.meta.activeTag(command) == tag) {
                count += 1;
            }
        }
        return count;
    }

    //
    // The first command of the given kind the storage sent.
    //
    fn firstOf(client: *const FakeClient, comptime tag: std.meta.Tag(S3Command)) S3Command {
        for (client.commands.items) |command| {
            if (std.meta.activeTag(command) == tag) {
                return command;
            }
        }
        unreachable;
    }
};

//
// A CloudStorage whose S3 client answers from the handler, and the client it answers with.
//
// The storage is returned by pointer because the client's `send` records the address of the client, which
// must not move once it is set.
//
const Fixture = struct {
    // Frees everything the test allocated.
    arena: std.heap.ArenaAllocator,

    // The client recording the commands.
    client: *FakeClient,

    // The storage under test.
    storage: *CloudStorage,

    // Allocates the test's data.
    allocator: std.mem.Allocator,

    //
    // Creates a storage that answers every command with the handler.
    //
    fn init(handler: Handler) !*Fixture {
        const fixture = try std.testing.allocator.create(Fixture);
        fixture.arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        const allocator = fixture.arena.allocator();
        const client = try allocator.create(FakeClient);
        client.* = .{
            .allocator = allocator,
            .commands = .empty,
            .handler = handler,
        };
        const storage = try allocator.create(CloudStorage);
        storage.* = CloudStorage.init(std.testing.io, "s3:", null);
        storage.s3.send = .{ .context = client, .function = FakeClient.send };
        fixture.client = client;
        fixture.storage = storage;
        fixture.allocator = allocator;
        return fixture;
    }

    //
    // Shuts the storage down and frees everything the test allocated.
    //
    fn deinit(self: *Fixture) void {
        self.storage.s3.deinit();
        self.arena.deinit();
        std.testing.allocator.destroy(self);
    }
};

//
// The contents of the object the fake server holds.
//
const objectContents = "the object body";

//
// Answers GetObject with the object, HeadObject with its length and last modified, and nothing else.
//
fn objectPresent(command: S3Command) anyerror!S3CommandOutput {
    return switch (command) {
        .GetObjectCommand => S3CommandOutput{ .GetObject = .{
            .Body = @constCast(objectContents),
            .ContentRange = null,
        } },
        .HeadObjectCommand => S3CommandOutput{ .HeadObject = .{
            .ContentType = "text/plain",
            .ContentLength = objectContents.len,
            .LastModified = 1_700_000_000_000,
            .ChecksumSHA256 = null,
        } },
        else => .none,
    };
}

//
// Answers GetObject with NoSuchKey.
//
fn objectMissing(command: S3Command) anyerror!S3CommandOutput {
    return switch (command) {
        .GetObjectCommand => s3_client.throwServiceException("NoSuchKey", "The specified key does not exist.", 404),
        else => .none,
    };
}

//
// Answers every command with nothing, which is what a server that accepts the request does for the commands
// whose output is not read.
//
fn accepted(command: S3Command) anyerror!S3CommandOutput {
    _ = command;
    return .none;
}

//
// Answers every command with the error of a server having trouble, as the S3 client reports a response whose
// <Error><Code> is SlowDown. It goes through throwServiceException rather than throwError so the client's record of
// the last HTTP status is set the way a real response sets it, which is what the "not found" checks read.
//
fn slowDown(command: S3Command) anyerror!S3CommandOutput {
    _ = command;
    return s3_client.throwServiceException("SlowDown", "Slow down", 503);
}

test "read returns the object's bytes" {
    const fixture = try Fixture.init(objectPresent);
    defer fixture.deinit();

    const result = try fixture.storage.read(fixture.allocator, std.testing.io, "bucket/dir/file.txt");
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings(objectContents, result.?);
    try std.testing.expectEqual(@as(usize, 1), fixture.client.countOf(.GetObjectCommand));
    try std.testing.expectEqualStrings("bucket", fixture.client.firstOf(.GetObjectCommand).GetObjectCommand.Bucket);
    try std.testing.expectEqualStrings("dir/file.txt", fixture.client.firstOf(.GetObjectCommand).GetObjectCommand.Key);
}

test "read returns undefined for an object that is not there" {
    const fixture = try Fixture.init(objectMissing);
    defer fixture.deinit();

    try std.testing.expect((try fixture.storage.read(fixture.allocator, std.testing.io, "bucket/dir/file.txt")) == null);
}

test "read returns an empty buffer for an object with no content" {
    const fixture = try Fixture.init(struct {
        fn handler(command: S3Command) anyerror!S3CommandOutput {
            return switch (command) {
                .GetObjectCommand => S3CommandOutput{ .GetObject = .{ .Body = null, .ContentRange = null } },
                else => .none,
            };
        }
    }.handler);
    defer fixture.deinit();

    // The SDK's Body is an empty stream for an empty object, so the read is empty rather than missing.
    const result = try fixture.storage.read(fixture.allocator, std.testing.io, "bucket/dir/file.txt");
    try std.testing.expect(result != null);
    try std.testing.expectEqual(@as(usize, 0), result.?.len);
}

test "read reports the error of a server that is having trouble, naming the file" {
    const fixture = try Fixture.init(slowDown);
    defer fixture.deinit();

    try std.testing.expectError(error.Thrown, fixture.storage.read(fixture.allocator, std.testing.io, "bucket/dir/file.txt"));

    //
    // (Zig: a WrappedError folds the cause's message into its own, so it reads twice: once from the format
    // and once from the cause, as every other WrappedError message in this package does.)
    //
    try std.testing.expectEqualStrings("Failed to read bucket/dir/file.txt: Slow down: Slow down", utils.errors.lastErrorMessage());
}

test "info gives the length, the content type and the last modified time of the object" {
    const fixture = try Fixture.init(objectPresent);
    defer fixture.deinit();

    const result = try fixture.storage.info(fixture.allocator, std.testing.io, "bucket/dir/file.txt");
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("text/plain", result.?.contentType.?);
    try std.testing.expectEqual(@as(u64, objectContents.len), result.?.length);
    try std.testing.expectEqual(@as(i64, 1_700_000_000_000), result.?.lastModified);
}

test "info returns undefined for an object that is not there" {
    const fixture = try Fixture.init(struct {
        fn handler(command: S3Command) anyerror!S3CommandOutput {
            return switch (command) {
                .HeadObjectCommand => s3_client.throwServiceException("NotFound", "Not Found", 404),
                else => .none,
            };
        }
    }.handler);
    defer fixture.deinit();

    try std.testing.expect((try fixture.storage.info(fixture.allocator, std.testing.io, "bucket/dir/file.txt")) == null);
}

test "info reports an error of the server other than the object not being there" {
    const fixture = try Fixture.init(struct {
        fn handler(command: S3Command) anyerror!S3CommandOutput {
            return switch (command) {
                .HeadObjectCommand => slowDown(command),
                else => .none,
            };
        }
    }.handler);
    defer fixture.deinit();

    try std.testing.expectError(error.Thrown, fixture.storage.info(fixture.allocator, std.testing.io, "bucket/dir/file.txt"));
    try std.testing.expectEqualStrings("Failed to get info for bucket/dir/file.txt: Slow down: Slow down", utils.errors.lastErrorMessage());
}

test "readableLength is the length in the info, because an object hands out what it holds" {
    const fixture = try Fixture.init(objectPresent);
    defer fixture.deinit();

    const info = (try fixture.storage.info(fixture.allocator, std.testing.io, "bucket/dir/file.txt")).?;
    try std.testing.expectEqual(info.length, fixture.storage.readableLength(info).?);
}

test "write sends the data as one PutObject with its content type" {
    const fixture = try Fixture.init(accepted);
    defer fixture.deinit();

    try fixture.storage.write(fixture.allocator, std.testing.io, "bucket/dir/file.txt", "text/plain", "hello");

    try std.testing.expectEqual(@as(usize, 1), fixture.client.countOf(.PutObjectCommand));
    const put = fixture.client.firstOf(.PutObjectCommand).PutObjectCommand;
    try std.testing.expectEqualStrings("dir/file.txt", put.Key);
    try std.testing.expectEqualStrings("hello", put.Body);
    try std.testing.expectEqualStrings("text/plain", put.ContentType.?);
    try std.testing.expectEqual(@as(?u64, 5), put.ContentLength);
    try std.testing.expect(put.IfNoneMatch == null);
}

test "write reports the error of a refused write, naming the file" {
    const fixture = try Fixture.init(struct {
        fn handler(command: S3Command) anyerror!S3CommandOutput {
            return switch (command) {
                .PutObjectCommand => s3_client.throwServiceException("AccessDenied", "Access Denied", 403),
                else => .none,
            };
        }
    }.handler);
    defer fixture.deinit();

    try std.testing.expectError(error.Thrown, fixture.storage.write(fixture.allocator, std.testing.io, "bucket/dir/file.txt", null, "hello"));
    try std.testing.expectEqualStrings("Failed to write to bucket/dir/file.txt: Access Denied: Access Denied", utils.errors.lastErrorMessage());
}

test "writeStream sends the bytes of the stream as one PutObject" {
    const fixture = try Fixture.init(accepted);
    defer fixture.deinit();

    var input = std.Io.Reader.fixed("streamed bytes");
    try fixture.storage.writeStream(fixture.allocator, std.testing.io, "bucket/dir/file.txt", null, &input, 14);

    try std.testing.expectEqual(@as(usize, 1), fixture.client.countOf(.PutObjectCommand));
    try std.testing.expectEqualStrings("streamed bytes", fixture.client.firstOf(.PutObjectCommand).PutObjectCommand.Body);
}

test "writeStream reports the error of a refused write, naming the file" {
    const fixture = try Fixture.init(slowDown);
    defer fixture.deinit();

    var input = std.Io.Reader.fixed("streamed bytes");
    try std.testing.expectError(error.Thrown, fixture.storage.writeStream(fixture.allocator, std.testing.io, "bucket/dir/file.txt", null, &input, 14));
    try std.testing.expectEqualStrings("Failed to write stream to bucket/dir/file.txt: Slow down: Slow down", utils.errors.lastErrorMessage());
}

test "readStream hands out a stream that reads the object" {
    const fixture = try Fixture.init(objectPresent);
    defer fixture.deinit();

    const rangeStream = try fixture.storage.readStream(fixture.allocator, std.testing.io, "bucket/dir/file.txt");
    defer rangeStream.destroy(std.testing.io);
    const body = try rangeStream.reader().allocRemaining(fixture.allocator, .unlimited);
    try std.testing.expectEqualStrings(objectContents, body);

    // A range request, not a whole-object one.
    try std.testing.expectEqual(@as(usize, 1), fixture.client.countOf(.GetObjectCommand));
    try std.testing.expect(fixture.client.firstOf(.GetObjectCommand).GetObjectCommand.Range != null);
    try std.testing.expectEqualStrings("dir/file.txt", fixture.client.firstOf(.GetObjectCommand).GetObjectCommand.Key);
}

test "readStream refuses a path that names no key" {
    const fixture = try Fixture.init(objectPresent);
    defer fixture.deinit();

    try std.testing.expectError(error.Thrown, fixture.storage.readStream(fixture.allocator, std.testing.io, "bucket-only"));
    try std.testing.expectEqual(@as(usize, 0), fixture.client.commands.items.len);
}

test "deleteFile sends a DeleteObject" {
    const fixture = try Fixture.init(accepted);
    defer fixture.deinit();

    try fixture.storage.deleteFile(fixture.allocator, std.testing.io, "bucket/dir/file.txt");
    try std.testing.expectEqual(@as(usize, 1), fixture.client.countOf(.DeleteObjectCommand));
    try std.testing.expectEqualStrings("dir/file.txt", fixture.client.firstOf(.DeleteObjectCommand).DeleteObjectCommand.Key);
}

test "deleteFile ignores an error, because the file not being there is the same outcome" {
    const fixture = try Fixture.init(slowDown);
    defer fixture.deinit();

    try fixture.storage.deleteFile(fixture.allocator, std.testing.io, "bucket/dir/file.txt");
    try std.testing.expectEqual(@as(usize, 1), fixture.client.countOf(.DeleteObjectCommand));
}

test "deleteDir deletes every object under the prefix in one batch" {
    const fixture = try Fixture.init(struct {
        fn handler(command: S3Command) anyerror!S3CommandOutput {
            return switch (command) {
                .ListObjectsV2Command => S3CommandOutput{ .ListObjectsV2 = .{
                    .Contents = &.{
                        .{ .Key = "dir/a.txt" },
                        .{ .Key = "dir/sub/b.txt" },
                    },
                    .CommonPrefixes = null,
                    .NextContinuationToken = null,
                    .IsTruncated = false,
                } },
                else => .none,
            };
        }
    }.handler);
    defer fixture.deinit();

    try fixture.storage.deleteDir(fixture.allocator, std.testing.io, "bucket/dir");

    try std.testing.expectEqual(@as(usize, 1), fixture.client.countOf(.ListObjectsV2Command));
    try std.testing.expectEqualStrings("dir/", fixture.client.firstOf(.ListObjectsV2Command).ListObjectsV2Command.Prefix);
    try std.testing.expectEqual(@as(usize, 1), fixture.client.countOf(.DeleteObjectsCommand));
    const deleted = fixture.client.firstOf(.DeleteObjectsCommand).DeleteObjectsCommand.Keys;
    try std.testing.expectEqual(@as(usize, 2), deleted.len);
    try std.testing.expectEqualStrings("dir/a.txt", deleted[0]);
    try std.testing.expectEqualStrings("dir/sub/b.txt", deleted[1]);
}

//
// How many listings the fake server has answered, so the second page can be told from the first.
//
var listingsAnswered: usize = 0;

test "deleteDir follows the continuation token until the listing is not truncated" {
    const fixture = try Fixture.init(struct {
        fn handler(command: S3Command) anyerror!S3CommandOutput {
            return switch (command) {
                .ListObjectsV2Command => S3CommandOutput{ .ListObjectsV2 = if (listingsAnswered == 0) blk: {
                    listingsAnswered += 1;
                    break :blk .{
                        .Contents = &.{.{ .Key = "dir/a.txt" }},
                        .CommonPrefixes = null,
                        .NextContinuationToken = "page2",
                        .IsTruncated = true,
                    };
                } else blk: {
                    listingsAnswered += 1;
                    break :blk .{
                        .Contents = &.{.{ .Key = "dir/b.txt" }},
                        .CommonPrefixes = null,
                        .NextContinuationToken = null,
                        .IsTruncated = false,
                    };
                } },
                else => .none,
            };
        }
    }.handler);
    defer fixture.deinit();
    listingsAnswered = 0;

    try fixture.storage.deleteDir(fixture.allocator, std.testing.io, "bucket/dir");

    try std.testing.expectEqual(@as(usize, 2), fixture.client.countOf(.ListObjectsV2Command));
    try std.testing.expectEqual(@as(usize, 2), fixture.client.countOf(.DeleteObjectsCommand));

    // Each page's objects are deleted as that page arrives, not at the end, and the second listing asks
    // for the rest with the token the first one returned.
    var listings: std.ArrayList([]const u8) = .empty;
    var batches: std.ArrayList([]const u8) = .empty;
    for (fixture.client.commands.items) |command| {
        switch (command) {
            .ListObjectsV2Command => |input| try listings.append(fixture.allocator, input.ContinuationToken orelse ""),
            .DeleteObjectsCommand => |input| try batches.append(fixture.allocator, input.Keys[0]),
            else => {},
        }
    }
    try std.testing.expectEqualStrings("", listings.items[0]);
    try std.testing.expectEqualStrings("page2", listings.items[1]);
    try std.testing.expectEqualStrings("dir/a.txt", batches.items[0]);
    try std.testing.expectEqualStrings("dir/b.txt", batches.items[1]);
}

test "deleteDir sends no batch delete when the directory holds nothing" {
    const fixture = try Fixture.init(struct {
        fn handler(command: S3Command) anyerror!S3CommandOutput {
            return switch (command) {
                .ListObjectsV2Command => S3CommandOutput{ .ListObjectsV2 = .{
                    .Contents = null,
                    .CommonPrefixes = null,
                    .NextContinuationToken = null,
                    .IsTruncated = false,
                } },
                else => .none,
            };
        }
    }.handler);
    defer fixture.deinit();

    try fixture.storage.deleteDir(fixture.allocator, std.testing.io, "bucket/dir");
    try std.testing.expectEqual(@as(usize, 0), fixture.client.countOf(.DeleteObjectsCommand));
}

test "deleteDir sends no batch delete for a listing that comes back empty rather than absent" {
    const fixture = try Fixture.init(struct {
        fn handler(command: S3Command) anyerror!S3CommandOutput {
            return switch (command) {
                .ListObjectsV2Command => S3CommandOutput{ .ListObjectsV2 = .{
                    .Contents = &.{},
                    .CommonPrefixes = null,
                    .NextContinuationToken = null,
                    .IsTruncated = false,
                } },
                else => .none,
            };
        }
    }.handler);
    defer fixture.deinit();

    try fixture.storage.deleteDir(fixture.allocator, std.testing.io, "bucket/dir");
    try std.testing.expectEqual(@as(usize, 0), fixture.client.countOf(.DeleteObjectsCommand));
}

test "deleteDir gives up quietly when the listing fails" {
    const fixture = try Fixture.init(slowDown);
    defer fixture.deinit();

    try fixture.storage.deleteDir(fixture.allocator, std.testing.io, "bucket/dir");
    try std.testing.expectEqual(@as(usize, 1), fixture.client.countOf(.ListObjectsV2Command));
    try std.testing.expectEqual(@as(usize, 0), fixture.client.countOf(.DeleteObjectsCommand));
}

test "deleteDir gives up quietly when the batch delete fails" {
    const fixture = try Fixture.init(struct {
        fn handler(command: S3Command) anyerror!S3CommandOutput {
            return switch (command) {
                .ListObjectsV2Command => S3CommandOutput{ .ListObjectsV2 = .{
                    .Contents = &.{.{ .Key = "dir/a.txt" }},
                    .CommonPrefixes = null,
                    .NextContinuationToken = null,
                    .IsTruncated = false,
                } },
                .DeleteObjectsCommand => slowDown(command),
                else => .none,
            };
        }
    }.handler);
    defer fixture.deinit();

    try fixture.storage.deleteDir(fixture.allocator, std.testing.io, "bucket/dir");
    try std.testing.expectEqual(@as(usize, 1), fixture.client.countOf(.DeleteObjectsCommand));
}

test "copyTo copies one bucket's key to another's" {
    const fixture = try Fixture.init(accepted);
    defer fixture.deinit();

    try fixture.storage.copyTo(fixture.allocator, std.testing.io, "src-bucket/dir/a.txt", "dst-bucket/dir/b.txt");

    try std.testing.expectEqual(@as(usize, 1), fixture.client.countOf(.CopyObjectCommand));
    const copy = fixture.client.firstOf(.CopyObjectCommand).CopyObjectCommand;
    try std.testing.expectEqualStrings("dst-bucket", copy.Bucket);
    try std.testing.expectEqualStrings("src-bucket/dir/a.txt", copy.CopySource);
    try std.testing.expectEqualStrings("dir/b.txt", copy.Key);
}

test "copyTo reports the error of a refused copy, naming both paths" {
    const fixture = try Fixture.init(slowDown);
    defer fixture.deinit();

    try std.testing.expectError(error.Thrown, fixture.storage.copyTo(fixture.allocator, std.testing.io, "src-bucket/dir/a.txt", "dst-bucket/dir/b.txt"));
    try std.testing.expectEqualStrings("Failed to copy from src-bucket/dir/a.txt to dst-bucket/dir/b.txt: Slow down: Slow down", utils.errors.lastErrorMessage());
}

test "checkWriteLock reads the lock out of the object" {
    const fixture = try Fixture.init(struct {
        fn handler(command: S3Command) anyerror!S3CommandOutput {
            return switch (command) {
                .GetObjectCommand => S3CommandOutput{ .GetObject = .{
                    .Body = @constCast("{\"owner\":\"first\",\"acquiredAt\":\"2024-02-29T23:59:59.999Z\",\"timestamp\":1709251199999}"),
                    .ContentRange = null,
                } },
                else => .none,
            };
        }
    }.handler);
    defer fixture.deinit();

    const lock = (try fixture.storage.checkWriteLock(fixture.allocator, std.testing.io, "bucket/.db/write.lock")).?;
    try std.testing.expectEqualStrings("first", lock.owner);
    try std.testing.expectEqual(@as(i64, 1709251199999), lock.timestamp);
    try std.testing.expectEqual(@as(i64, 1709251199999), lock.acquiredAt.epochMilliseconds);
}

test "checkWriteLock returns undefined for a lock that is not there" {
    const fixture = try Fixture.init(objectMissing);
    defer fixture.deinit();

    try std.testing.expect((try fixture.storage.checkWriteLock(fixture.allocator, std.testing.io, "bucket/.db/write.lock")) == null);
}

test "checkWriteLock returns undefined for a lock object with no content" {
    const fixture = try Fixture.init(struct {
        fn handler(command: S3Command) anyerror!S3CommandOutput {
            return switch (command) {
                .GetObjectCommand => S3CommandOutput{ .GetObject = .{ .Body = null, .ContentRange = null } },
                else => .none,
            };
        }
    }.handler);
    defer fixture.deinit();

    try std.testing.expect((try fixture.storage.checkWriteLock(fixture.allocator, std.testing.io, "bucket/.db/write.lock")) == null);
}

test "checkWriteLock reports a lock file that is not a lock" {
    const fixture = try Fixture.init(struct {
        fn handler(command: S3Command) anyerror!S3CommandOutput {
            return switch (command) {
                .GetObjectCommand => S3CommandOutput{ .GetObject = .{
                    .Body = @constCast("{ not json"),
                    .ContentRange = null,
                } },
                else => .none,
            };
        }
    }.handler);
    defer fixture.deinit();

    try std.testing.expectError(error.Thrown, fixture.storage.checkWriteLock(fixture.allocator, std.testing.io, "bucket/.db/write.lock"));
    try std.testing.expectEqualStrings("WrappedError", utils.errors.lastErrorName());
}

test "checkWriteLock reports an error of the server other than the lock not being there" {
    const fixture = try Fixture.init(slowDown);
    defer fixture.deinit();

    try std.testing.expectError(error.Thrown, fixture.storage.checkWriteLock(fixture.allocator, std.testing.io, "bucket/.db/write.lock"));
    try std.testing.expectEqualStrings("Failed to check write lock for bucket/.db/write.lock: Slow down: Slow down", utils.errors.lastErrorMessage());
}

test "releaseWriteLock deletes the lock object" {
    const fixture = try Fixture.init(accepted);
    defer fixture.deinit();

    try fixture.storage.releaseWriteLock(fixture.allocator, std.testing.io, "bucket/.db/write.lock");
    try std.testing.expectEqual(@as(usize, 1), fixture.client.countOf(.DeleteObjectCommand));
    try std.testing.expectEqualStrings(".db/write.lock", fixture.client.firstOf(.DeleteObjectCommand).DeleteObjectCommand.Key);
}

test "releaseWriteLock ignores an error, because the lock not being there is the same outcome" {
    const fixture = try Fixture.init(slowDown);
    defer fixture.deinit();

    try fixture.storage.releaseWriteLock(fixture.allocator, std.testing.io, "bucket/.db/write.lock");
    try std.testing.expectEqual(@as(usize, 1), fixture.client.countOf(.DeleteObjectCommand));
}

test "every operation drops the leading slash of a key, as TypeScript does" {
    const fixture = try Fixture.init(struct {
        fn handler(command: S3Command) anyerror!S3CommandOutput {
            return switch (command) {
                .ListObjectsV2Command => S3CommandOutput{ .ListObjectsV2 = .{
                    .Contents = null,
                    .CommonPrefixes = null,
                    .NextContinuationToken = null,
                    .IsTruncated = false,
                } },
                .GetObjectCommand => S3CommandOutput{ .GetObject = .{
                    .Body = @constCast("{\"owner\":\"first\",\"acquiredAt\":\"2024-02-29T23:59:59.999Z\",\"timestamp\":1709251199999}"),
                    .ContentRange = null,
                } },
                else => objectPresent(command),
            };
        }
    }.handler);
    defer fixture.deinit();

    const allocator = fixture.allocator;
    const io = std.testing.io;
    _ = try fixture.storage.listFiles(allocator, io, "bucket//dir", 10, null);
    _ = try fixture.storage.listDirs(allocator, io, "bucket//dir", 10, null);
    _ = try fixture.storage.read(allocator, io, "bucket//dir/file.txt");
    _ = try fixture.storage.info(allocator, io, "bucket//dir/file.txt");
    try fixture.storage.write(allocator, io, "bucket//dir/file.txt", null, "x");
    var emptyInput = std.Io.Reader.fixed("");
    try fixture.storage.writeStream(allocator, io, "bucket//dir/file.txt", null, &emptyInput, 0);
    try fixture.storage.deleteFile(allocator, io, "bucket//dir/file.txt");
    try fixture.storage.deleteDir(allocator, io, "bucket//dir");
    try fixture.storage.copyTo(allocator, io, "bucket//a.txt", "bucket//b.txt");
    _ = try fixture.storage.checkWriteLock(allocator, io, "bucket//.db/write.lock");
    try fixture.storage.releaseWriteLock(allocator, io, "bucket//.db/write.lock");

    for (fixture.client.commands.items) |command| {
        switch (command) {
            .ListObjectsV2Command => |input| try std.testing.expect(!std.mem.startsWith(u8, input.Prefix, "/")),
            .GetObjectCommand => |input| try std.testing.expect(!std.mem.startsWith(u8, input.Key, "/")),
            .HeadObjectCommand => |input| try std.testing.expect(!std.mem.startsWith(u8, input.Key, "/")),
            .PutObjectCommand => |input| try std.testing.expect(!std.mem.startsWith(u8, input.Key, "/")),
            .DeleteObjectCommand => |input| try std.testing.expect(!std.mem.startsWith(u8, input.Key, "/")),
            .DeleteObjectsCommand => |input| {
                for (input.Keys) |key| {
                    try std.testing.expect(!std.mem.startsWith(u8, key, "/"));
                }
            },
            .CopyObjectCommand => |input| try std.testing.expect(!std.mem.startsWith(u8, input.Key, "/")),
        }
    }
}

test "a path that names no bucket, or an empty key, is refused by every operation that parses one" {
    const fixture = try Fixture.init(objectPresent);
    defer fixture.deinit();

    const allocator = fixture.allocator;
    const io = std.testing.io;
    try std.testing.expectError(error.Thrown, fixture.storage.read(allocator, io, "bucket-only"));
    try std.testing.expectEqualStrings("Invalid path: bucket-only. Expected <bucket-name>/<path>", utils.errors.lastErrorMessage());
    try std.testing.expectError(error.Thrown, fixture.storage.read(allocator, io, "/dir/file.txt"));
    try std.testing.expectEqualStrings("Invalid path: /dir/file.txt. Expected <bucket-name>/<path>", utils.errors.lastErrorMessage());
    try std.testing.expectError(error.Thrown, fixture.storage.read(allocator, io, "bucket/"));
    try std.testing.expectEqualStrings("Invalid path: bucket/. Expected <bucket-name>/<path>", utils.errors.lastErrorMessage());

    try std.testing.expectError(error.Thrown, fixture.storage.fileExists(allocator, io, "bucket-only"));
    try std.testing.expectError(error.Thrown, fixture.storage.dirExists(allocator, io, "bucket/"));
    try std.testing.expectError(error.Thrown, fixture.storage.copyTo(allocator, io, "bucket/a", "bucket/"));
    try std.testing.expectError(error.Thrown, fixture.storage.deleteDir(allocator, io, "bucket-only"));
    try std.testing.expectError(error.Thrown, fixture.storage.storedHash(allocator, io, "bucket-only"));
    try std.testing.expectError(error.Thrown, fixture.storage.checkWriteLock(allocator, io, "bucket-only"));

    // Nothing reached the server.
    try std.testing.expectEqual(@as(usize, 0), fixture.client.commands.items.len);
}

test "isEmpty is true for a prefix that holds neither files nor directories" {
    const fixture = try Fixture.init(struct {
        fn handler(command: S3Command) anyerror!S3CommandOutput {
            _ = command;
            return S3CommandOutput{ .ListObjectsV2 = .{
                .Contents = null,
                .CommonPrefixes = null,
                .NextContinuationToken = null,
                .IsTruncated = false,
            } };
        }
    }.handler);
    defer fixture.deinit();

    try std.testing.expect(try fixture.storage.isEmpty(fixture.allocator, std.testing.io, "bucket/dir"));
    try std.testing.expectEqual(@as(usize, 2), fixture.client.countOf(.ListObjectsV2Command));
}

test "isEmpty is false for a prefix that holds a file, asking only for the first page" {
    const fixture = try Fixture.init(struct {
        fn handler(command: S3Command) anyerror!S3CommandOutput {
            _ = command;
            return S3CommandOutput{ .ListObjectsV2 = .{
                .Contents = &.{.{ .Key = "dir/a.txt" }},
                .CommonPrefixes = null,
                .NextContinuationToken = null,
                .IsTruncated = false,
            } };
        }
    }.handler);
    defer fixture.deinit();

    try std.testing.expect(!try fixture.storage.isEmpty(fixture.allocator, std.testing.io, "bucket/dir"));

    // Only the file listing: the directory listing is not asked for.
    try std.testing.expectEqual(@as(usize, 1), fixture.client.countOf(.ListObjectsV2Command));
    try std.testing.expectEqual(@as(?u32, 1), fixture.client.firstOf(.ListObjectsV2Command).ListObjectsV2Command.MaxKeys);
}

test "isEmpty reports an error of the server, naming what it was listing" {
    const fixture = try Fixture.init(slowDown);
    defer fixture.deinit();

    try std.testing.expectError(error.Thrown, fixture.storage.isEmpty(fixture.allocator, std.testing.io, "bucket/dir"));
    try std.testing.expectEqualStrings("Failed to list files in bucket/dir: Slow down: Slow down", utils.errors.lastErrorMessage());
}

test "dirExists is true for a prefix with one object under it" {
    const fixture = try Fixture.init(struct {
        fn handler(command: S3Command) anyerror!S3CommandOutput {
            _ = command;
            return S3CommandOutput{ .ListObjectsV2 = .{
                .Contents = &.{.{ .Key = "dir/a.txt" }},
                .CommonPrefixes = null,
                .NextContinuationToken = null,
                .IsTruncated = false,
            } };
        }
    }.handler);
    defer fixture.deinit();

    try std.testing.expect(try fixture.storage.dirExists(fixture.allocator, std.testing.io, "bucket/dir"));
    try std.testing.expectEqualStrings("dir/", fixture.client.firstOf(.ListObjectsV2Command).ListObjectsV2Command.Prefix);
}

test "dirExists is false for a prefix with nothing under it" {
    const fixture = try Fixture.init(struct {
        fn handler(command: S3Command) anyerror!S3CommandOutput {
            _ = command;
            return S3CommandOutput{ .ListObjectsV2 = .{
                .Contents = &.{},
                .CommonPrefixes = null,
                .NextContinuationToken = null,
                .IsTruncated = false,
            } };
        }
    }.handler);
    defer fixture.deinit();

    try std.testing.expect(!try fixture.storage.dirExists(fixture.allocator, std.testing.io, "bucket/dir"));
}

test "dirExists normalises a key that starts with a slash, whatever order the slashes arrive in" {
    const fixture = try Fixture.init(struct {
        fn handler(command: S3Command) anyerror!S3CommandOutput {
            _ = command;
            return S3CommandOutput{ .ListObjectsV2 = .{
                .Contents = &.{.{ .Key = "dir/a.txt" }},
                .CommonPrefixes = null,
                .NextContinuationToken = null,
                .IsTruncated = false,
            } };
        }
    }.handler);
    defer fixture.deinit();

    _ = try fixture.storage.dirExists(fixture.allocator, std.testing.io, "bucket//dir");
    try std.testing.expectEqualStrings("dir/", fixture.client.firstOf(.ListObjectsV2Command).ListObjectsV2Command.Prefix);
}

test "dirExists reports an error of the server, naming what it was doing" {
    const fixture = try Fixture.init(slowDown);
    defer fixture.deinit();

    try std.testing.expectError(error.Thrown, fixture.storage.dirExists(fixture.allocator, std.testing.io, "bucket/dir"));
    try std.testing.expectEqualStrings("Failed to check if directory exists: Slow down: Slow down", utils.errors.lastErrorMessage());
}

test "fileExists is true for an object the server has" {
    const fixture = try Fixture.init(objectPresent);
    defer fixture.deinit();

    try std.testing.expect(try fixture.storage.fileExists(fixture.allocator, std.testing.io, "bucket/dir/file.txt"));

    // fileExists does not ask for the checksum storedHash asks for.
    try std.testing.expectEqual(@as(?[]const u8, null), fixture.client.firstOf(.HeadObjectCommand).HeadObjectCommand.ChecksumMode);
}

test "fileExists is false for an object the server has not got" {
    const fixture = try Fixture.init(struct {
        fn handler(command: S3Command) anyerror!S3CommandOutput {
            return switch (command) {
                .HeadObjectCommand => s3_client.throwServiceException("NotFound", "Not Found", 404),
                else => .none,
            };
        }
    }.handler);
    defer fixture.deinit();

    try std.testing.expect(!try fixture.storage.fileExists(fixture.allocator, std.testing.io, "bucket/dir/file.txt"));
}

test "fileExists is false for an object the server answers with 404 under another error name" {
    const fixture = try Fixture.init(struct {
        fn handler(command: S3Command) anyerror!S3CommandOutput {
            return switch (command) {
                .HeadObjectCommand => s3_client.throwServiceException("SomethingElse", "Something Else", 404),
                else => .none,
            };
        }
    }.handler);
    defer fixture.deinit();

    try std.testing.expect(!try fixture.storage.fileExists(fixture.allocator, std.testing.io, "bucket/dir/file.txt"));
}

test "fileExists reports an error of the server other than the object not being there" {
    const fixture = try Fixture.init(slowDown);
    defer fixture.deinit();

    try std.testing.expectError(error.Thrown, fixture.storage.fileExists(fixture.allocator, std.testing.io, "bucket/dir/file.txt"));
    try std.testing.expectEqualStrings("Failed to check if file exists: Slow down: Slow down", utils.errors.lastErrorMessage());
}

test "listFiles drops the prefix from each name and skips an empty one" {
    const fixture = try Fixture.init(struct {
        fn handler(command: S3Command) anyerror!S3CommandOutput {
            _ = command;
            return S3CommandOutput{ .ListObjectsV2 = .{
                .Contents = &.{
                    .{ .Key = "dir/a.txt" },
                    .{ .Key = "dir/" },
                    .{ .Key = "dir/sub/b.txt" },
                },
                .CommonPrefixes = null,
                .NextContinuationToken = "page2",
                .IsTruncated = true,
            } };
        }
    }.handler);
    defer fixture.deinit();

    const files = try fixture.storage.listFiles(fixture.allocator, std.testing.io, "bucket/dir", 10, null);
    try std.testing.expectEqual(@as(usize, 2), files.names.len);
    try std.testing.expectEqualStrings("a.txt", files.names[0]);
    try std.testing.expectEqualStrings("b.txt", files.names[1]);
    try std.testing.expectEqualStrings("page2", files.next.?);

    // The prefix is the directory with a trailing slash, and the delimiter is what groups its
    // subdirectories into CommonPrefixes rather than listing their contents.
    try std.testing.expectEqualStrings("dir/", fixture.client.firstOf(.ListObjectsV2Command).ListObjectsV2Command.Prefix);
    try std.testing.expectEqualStrings("/", fixture.client.firstOf(.ListObjectsV2Command).ListObjectsV2Command.Delimiter.?);
    try std.testing.expectEqual(@as(?u32, 10), fixture.client.firstOf(.ListObjectsV2Command).ListObjectsV2Command.MaxKeys);
}

test "listFiles returns no names for a bucket whose listing has no contents at all" {
    const fixture = try Fixture.init(struct {
        fn handler(command: S3Command) anyerror!S3CommandOutput {
            _ = command;
            return S3CommandOutput{ .ListObjectsV2 = .{
                .Contents = null,
                .CommonPrefixes = null,
                .NextContinuationToken = null,
                .IsTruncated = false,
            } };
        }
    }.handler);
    defer fixture.deinit();

    const files = try fixture.storage.listFiles(fixture.allocator, std.testing.io, "bucket/dir", 10, null);
    try std.testing.expectEqual(@as(usize, 0), files.names.len);
    try std.testing.expect(files.next == null);
}

test "listDirs drops the trailing slash of each prefix and skips an empty one" {
    const fixture = try Fixture.init(struct {
        fn handler(command: S3Command) anyerror!S3CommandOutput {
            _ = command;
            return S3CommandOutput{ .ListObjectsV2 = .{
                .Contents = null,
                .CommonPrefixes = &.{
                    .{ .Prefix = "dir/sub/" },
                    .{ .Prefix = "/" },
                },
                .NextContinuationToken = null,
                .IsTruncated = false,
            } };
        }
    }.handler);
    defer fixture.deinit();

    const dirs = try fixture.storage.listDirs(fixture.allocator, std.testing.io, "bucket/dir", 10, null);
    try std.testing.expectEqual(@as(usize, 1), dirs.names.len);
    try std.testing.expectEqualStrings("sub", dirs.names[0]);
    try std.testing.expect(dirs.next == null);
}

test "listFiles and listDirs report an error of the server, each naming what it was listing" {
    const fixture = try Fixture.init(slowDown);
    defer fixture.deinit();

    try std.testing.expectError(error.Thrown, fixture.storage.listFiles(fixture.allocator, std.testing.io, "bucket/dir", 10, null));
    try std.testing.expectEqualStrings("Failed to list files in bucket/dir: Slow down: Slow down", utils.errors.lastErrorMessage());
    try std.testing.expectError(error.Thrown, fixture.storage.listDirs(fixture.allocator, std.testing.io, "bucket/dir", 10, null));
    try std.testing.expectEqualStrings("Failed to list directories in bucket/dir: Slow down: Slow down", utils.errors.lastErrorMessage());
}

test "the continuation token reaches the listing, so a second page asks for the rest" {
    const fixture = try Fixture.init(struct {
        fn handler(command: S3Command) anyerror!S3CommandOutput {
            _ = command;
            return S3CommandOutput{ .ListObjectsV2 = .{
                .Contents = null,
                .CommonPrefixes = null,
                .NextContinuationToken = null,
                .IsTruncated = false,
            } };
        }
    }.handler);
    defer fixture.deinit();

    _ = try fixture.storage.listFiles(fixture.allocator, std.testing.io, "bucket/dir", 10, "page2");
    try std.testing.expectEqualStrings("page2", fixture.client.firstOf(.ListObjectsV2Command).ListObjectsV2Command.ContinuationToken.?);
}

test "the root of a bucket is listed with the prefix of the whole bucket and no delimiter from dirExists" {
    const fixture = try Fixture.init(struct {
        fn handler(command: S3Command) anyerror!S3CommandOutput {
            _ = command;
            return S3CommandOutput{ .ListObjectsV2 = .{
                .Contents = &.{.{ .Key = "top.txt" }},
                .CommonPrefixes = null,
                .NextContinuationToken = null,
                .IsTruncated = false,
            } };
        }
    }.handler);
    defer fixture.deinit();

    const files = try fixture.storage.listFiles(fixture.allocator, std.testing.io, "bucket//", 10, null);
    try std.testing.expectEqual(@as(usize, 1), files.names.len);
    try std.testing.expectEqualStrings("", fixture.client.firstOf(.ListObjectsV2Command).ListObjectsV2Command.Prefix);
    try std.testing.expectEqualStrings("/", fixture.client.firstOf(.ListObjectsV2Command).ListObjectsV2Command.Delimiter.?);

    _ = try fixture.storage.dirExists(fixture.allocator, std.testing.io, "bucket//");
    try std.testing.expectEqual(@as(usize, 2), fixture.client.countOf(.ListObjectsV2Command));
    const dirListing = fixture.client.commands.items[1].ListObjectsV2Command;
    try std.testing.expectEqualStrings("", dirListing.Prefix);
    try std.testing.expect(dirListing.Delimiter == null);
}