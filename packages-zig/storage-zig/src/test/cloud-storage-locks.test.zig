//
// Tests for the write locks of CloudStorage (port of src/tests/cloud-storage-locks.test.ts).
//

const std = @import("std");
const storage_zig = @import("storage-zig");
const utils = @import("utils-zig");

const CloudStorage = storage_zig.cloud_storage.CloudStorage;
const s3_client = storage_zig.s3_client;
const S3Command = s3_client.S3Command;
const S3CommandOutput = s3_client.S3CommandOutput;
const Date = utils.timestamp_provider.Date;

//
// The error S3 returns from a conditional write when the lock object already exists.
//
fn preconditionFailed() anyerror {
    return s3_client.throwServiceException("PreconditionFailed", "At least one of the pre-conditions you specified did not hold", 412);
}

//
// The error S3 returns from a read when the object is not there.
//
fn noSuchKey() anyerror {
    return s3_client.throwServiceException("NoSuchKey", "The specified key does not exist.", 404);
}

//
// A lock object body as S3 hands it back, naming its owner and when it was taken.
//
fn lockBody(allocator: std.mem.Allocator, owner: []const u8, timestamp: i64) !S3CommandOutput {
    const body = try std.fmt.allocPrint(allocator, "{{\"owner\":\"{s}\",\"acquiredAt\":\"{s}\",\"timestamp\":{d}}}", .{
        owner,
        try (Date{ .epochMilliseconds = timestamp }).toISOString(allocator),
        timestamp,
    });
    return .{ .GetObject = .{ .Body = body, .ContentRange = null } };
}

//
// The name of a command, as the TypeScript reads it from `command.constructor.name`.
//
fn commandName(command: S3Command) []const u8 {
    return @tagName(command);
}

//
// Answers a command for a test (the TypeScript test's handler).
//
const Handler = *const fn (sender: *Sender, name: []const u8) anyerror!S3CommandOutput;

//
// Replaces the storage's S3 client with one that answers from a handler and records the commands it was sent,
// so a test can drive acquireWriteLock through an exact server response (the TypeScript's createStorage).
//
const Sender = struct {
    // Allocates the recorded command names and the answers.
    allocator: std.mem.Allocator,

    // The names of the commands sent, in order.
    sent: std.ArrayList([]const u8),

    // Answers each command.
    handler: Handler,

    // The number of PutObjectCommands answered so far (used by one test's handler).
    puts: u32,

    //
    // Records the command and answers it with the handler.
    //
    fn send(context: *anyopaque, command: S3Command) anyerror!S3CommandOutput {
        const sender: *Sender = @ptrCast(@alignCast(context));
        const name = commandName(command);
        try sender.sent.append(sender.allocator, name);
        return sender.handler(sender, name);
    }

    //
    // True when a command with the name was sent.
    //
    fn wasSent(sender: *const Sender, name: []const u8) bool {
        for (sender.sent.items) |sentName| {
            if (std.mem.eql(u8, sentName, name)) {
                return true;
            }
        }
        return false;
    }
};

//
// A CloudStorage whose S3 client answers from the handler.
//
fn createStorage(allocator: std.mem.Allocator, sender: *Sender, handler: Handler) CloudStorage {
    sender.* = .{
        .allocator = allocator,
        .sent = .empty,
        .handler = handler,
        .puts = 0,
    };
    var storage = CloudStorage.init(std.testing.io, "s3:", null);
    storage.s3.send = .{ .context = sender, .function = Sender.send };
    return storage;
}

//
// The lock the tests acquire.
//
const lockPath = "test-bucket/db/.db/write.lock";

//
// The current time in milliseconds (TypeScript: `Date.now()`).
//
fn now() i64 {
    return std.Io.Clock.real.now(std.testing.io).toMilliseconds();
}

//
// Handler: another owner holds a live lock.
//
fn liveLockHandler(sender: *Sender, name: []const u8) anyerror!S3CommandOutput {
    if (std.mem.eql(u8, name, "PutObjectCommand")) {
        return preconditionFailed();
    }
    return lockBody(sender.allocator, "owner-a", now());
}

test "refuses the lock while another owner holds a live one" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var sender: Sender = undefined;
    var storage = createStorage(arena.allocator(), &sender, liveLockHandler);
    defer storage.s3.deinit();

    try std.testing.expectEqual(false, try storage.acquireWriteLock(arena.allocator(), std.testing.io, lockPath, "owner-b"));
    try std.testing.expect(!sender.wasSent("DeleteObjectCommand"));
}

//
// Handler: the lock is there, but reading it back returns nothing.
//
fn absentOnReadHandler(sender: *Sender, name: []const u8) anyerror!S3CommandOutput {
    _ = sender;
    if (std.mem.eql(u8, name, "PutObjectCommand")) {
        return preconditionFailed();
    }
    return noSuchKey();
}

//
// The failure this pins: the lock is there, because the conditional write was refused, but
// reading it back returns nothing because the read raced its owner. Treating that as a corrupt
// lock and breaking it put three processes in the critical section at once.
//
test "refuses the lock when it is there but reads back as absent" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var sender: Sender = undefined;
    var storage = createStorage(arena.allocator(), &sender, absentOnReadHandler);
    defer storage.s3.deinit();

    try std.testing.expectEqual(false, try storage.acquireWriteLock(arena.allocator(), std.testing.io, lockPath, "owner-b"));
    try std.testing.expect(!sender.wasSent("DeleteObjectCommand"));
}

//
// Handler: a stale lock is there until it is deleted.
//
fn staleLockHandler(sender: *Sender, name: []const u8) anyerror!S3CommandOutput {
    if (std.mem.eql(u8, name, "PutObjectCommand")) {
        sender.puts += 1;
        if (sender.puts == 1) {
            return preconditionFailed(); // The stale lock is still there.
        }
        return .none; // The write after the delete takes it.
    }
    if (std.mem.eql(u8, name, "DeleteObjectCommand")) {
        return .none;
    }
    return lockBody(sender.allocator, "owner-a", now() - 60_000);
}

test "still breaks a lock that has aged past the timeout and takes it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var sender: Sender = undefined;
    var storage = createStorage(arena.allocator(), &sender, staleLockHandler);
    defer storage.s3.deinit();

    try std.testing.expectEqual(true, try storage.acquireWriteLock(arena.allocator(), std.testing.io, lockPath, "owner-b"));
    try std.testing.expect(sender.wasSent("DeleteObjectCommand"));
}
