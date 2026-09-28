//
// Tests for CloudStorage.writeStreamHashed (port of src/tests/cloud-storage-write-stream-hashed.test.ts), and for
// CloudStorage.storedHash, which has no test of its own in TypeScript.
//

const std = @import("std");
const storage_zig = @import("storage-zig");
const utils = @import("utils-zig");

const CloudStorage = storage_zig.cloud_storage.CloudStorage;
const s3_client = storage_zig.s3_client;
const S3Command = s3_client.S3Command;
const S3CommandOutput = s3_client.S3CommandOutput;

//
// Answers a command for a test (the TypeScript test's handler).
//
const Handler = *const fn (commandName: []const u8) anyerror!S3CommandOutput;

//
// A CloudStorage whose S3 client is replaced by one that records the commands it was sent and
// answers from the given handler, so a test can see which upload path a body of a given size takes
// without an S3 server anywhere.
//
const FakeClient = struct {
    // Allocates the recorded commands.
    allocator: std.mem.Allocator,

    // The name of each command the storage sent, in order.
    sent: std.ArrayList([]const u8),

    // The input of each command the storage sent, in the same order.
    inputs: std.ArrayList(S3Command),

    // Answers each command.
    handler: Handler,

    //
    // Records the command and answers it with the handler.
    //
    fn send(context: *anyopaque, command: S3Command) anyerror!S3CommandOutput {
        const client: *FakeClient = @ptrCast(@alignCast(context));
        try client.sent.append(client.allocator, @tagName(command));
        try client.inputs.append(client.allocator, command);
        return client.handler(@tagName(command));
    }
};

//
// Creates a CloudStorage whose S3 client answers from the handler (the TypeScript's createStorage).
//
fn createStorage(allocator: std.mem.Allocator, client: *FakeClient, handler: Handler) CloudStorage {
    client.* = .{
        .allocator = allocator,
        .sent = .empty,
        .inputs = .empty,
        .handler = handler,
    };
    var storage = CloudStorage.init(std.testing.io, "s3:", null);
    storage.s3.send = .{ .context = client, .function = FakeClient.send };
    return storage;
}

//
// Answers every command with an empty response.
//
fn emptyResponse(commandName: []const u8) anyerror!S3CommandOutput {
    _ = commandName;
    return .none;
}

//
// Refuses every command.
//
fn accessDenied(commandName: []const u8) anyerror!S3CommandOutput {
    _ = commandName;
    return utils.errors.throwError("Access Denied", .{});
}

//
// A body of the given length that nothing in these tests reads.
//
fn aBody() std.Io.Reader {
    return std.Io.Reader.fixed("");
}

//
// The hash the tests hand over.
//
const hash = [_]u8{7} ** 32;

//
// The base64 of the hash (TypeScript: `hash.toString('base64')`).
//
fn hashBase64(allocator: std.mem.Allocator) ![]const u8 {
    const encoded = try allocator.alloc(u8, std.base64.standard.Encoder.calcSize(hash.len));
    return std.base64.standard.Encoder.encode(encoded, &hash);
}

//
// Every file a phone library holds must go up as one request.
//
// A multipart upload cannot be handed a file: its uploader reads the stream into a buffer per
// part, and on a phone bytes reach a buffer only by crossing the host bridge as base64, twice.
// Measured on a Pixel 6 against MinIO on the same LAN, with the network proven to carry 11.8MB/s
// from that phone, every five megabyte part took 2.2 to 2.5 seconds to send and about as long
// again to read in, while whole files under the old ceiling went up in under a second each.
//
test "a video sized body goes up as one request carrying the whole object hash" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var client: FakeClient = undefined;
    var storage = createStorage(allocator, &client, emptyResponse);
    defer storage.s3.deinit();

    var body = aBody();
    const verifiedByTheStore = try storage.writeStreamHashed(allocator, std.testing.io, "bucket/db/asset/one", "video/mp4", &body, 79 * 1024 * 1024, &hash);

    try std.testing.expectEqual(@as(usize, 1), client.sent.items.len);
    try std.testing.expectEqualStrings("PutObjectCommand", client.sent.items[0]);
    try std.testing.expectEqualStrings(try hashBase64(allocator), client.inputs.items[0].PutObjectCommand.ChecksumSHA256.?);
    try std.testing.expectEqual(@as(?u64, 79 * 1024 * 1024), client.inputs.items[0].PutObjectCommand.ContentLength);

    // The server checked the body against that hash, so the caller has nothing left to ask.
    try std.testing.expectEqual(true, verifiedByTheStore);
}

test "a photo sized body goes up as one request too" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var client: FakeClient = undefined;
    var storage = createStorage(allocator, &client, emptyResponse);
    defer storage.s3.deinit();

    var body = aBody();
    try std.testing.expectEqual(true, try storage.writeStreamHashed(allocator, std.testing.io, "bucket/db/asset/two", "image/jpeg", &body, 2 * 1024 * 1024, &hash));
    try std.testing.expectEqual(@as(usize, 1), client.sent.items.len);
    try std.testing.expectEqualStrings("PutObjectCommand", client.sent.items[0]);
}

//
// A body too large for one request still has a path, because S3 refuses a single PUT over five
// gigabytes.
//
test "a body larger than one request allows goes up in parts" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var client: FakeClient = undefined;
    var storage = createStorage(allocator, &client, emptyResponse);
    defer storage.s3.deinit();

    // False says the store did not check the bytes against the hash, which is what the multipart
    // path means: a multipart checksum is a hash of the parts' hashes rather than of the object,
    // so it cannot be compared with the hash the database holds and the caller has to verify.
    var body = aBody();
    try std.testing.expectEqual(false, try storage.writeStreamHashed(allocator, std.testing.io, "bucket/db/asset/huge", "video/mp4", &body, 3 * 1024 * 1024 * 1024, &hash));

    // No request carried the whole-object hash, because none of them could.
    for (client.inputs.items) |input| {
        try std.testing.expect(input.PutObjectCommand.ChecksumSHA256 == null);
    }
}

//
// A caller that cannot say how long its stream is must not have a length invented for it.
//
// An encrypted source reads out plaintext while holding ciphertext and cannot say how long the
// plaintext is, so it says so. Declaring the stored size in its place made every request promise
// more than it sent, and S3 sat waiting thirty seconds for the rest before refusing the write.
//
test "a body of unknown length is sent without one declared" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var client: FakeClient = undefined;
    var storage = createStorage(allocator, &client, emptyResponse);
    defer storage.s3.deinit();

    // False, because nothing compared what landed against the hash: the uploader reads the stream
    // to find out how long it is and cannot carry a whole-object checksum while doing it.
    var body = aBody();
    try std.testing.expectEqual(false, try storage.writeStreamHashed(allocator, std.testing.io, "bucket/db/thumb/four", "image/jpeg", &body, null, &hash));

    for (client.inputs.items) |input| {
        try std.testing.expect(input.PutObjectCommand.ContentLength == null);
    }
}

//
// A failed write must say so rather than report a copy that never happened.
//
test "a refused write is reported, naming the file" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var client: FakeClient = undefined;
    var storage = createStorage(allocator, &client, accessDenied);
    defer storage.s3.deinit();

    var body = aBody();
    try std.testing.expectError(error.Thrown, storage.writeStreamHashed(allocator, std.testing.io, "bucket/db/asset/three", "image/jpeg", &body, 1024, &hash));
    try std.testing.expect(std.mem.indexOf(u8, utils.errors.lastErrorMessage(), "bucket/db/asset/three") != null);
}

//
// Answers a HEAD with the checksum of the tests' hash.
//
fn headWithChecksum(commandName: []const u8) anyerror!S3CommandOutput {
    _ = commandName;
    return .{ .HeadObject = .{
        .ContentType = null,
        .ContentLength = 0,
        .LastModified = 0,
        .ChecksumSHA256 = "BwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwc=",
    } };
}

//
// Answers a HEAD with the composite checksum of a multipart upload.
//
fn headWithCompositeChecksum(commandName: []const u8) anyerror!S3CommandOutput {
    _ = commandName;
    return .{ .HeadObject = .{
        .ContentType = null,
        .ContentLength = 0,
        .LastModified = 0,
        .ChecksumSHA256 = "BwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwc=-3",
    } };
}

//
// Answers a HEAD as S3 does for an object that is not there.
//
fn notFound(commandName: []const u8) anyerror!S3CommandOutput {
    _ = commandName;
    return s3_client.throwServiceException("NotFound", "Not Found", 404);
}

//
// storedHash has no test of its own in TypeScript; what it answers for an S3 object is pinned here.
//
test "storedHash asks for the checksum and decodes the one S3 kept" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var client: FakeClient = undefined;
    var storage = createStorage(allocator, &client, headWithChecksum);
    defer storage.s3.deinit();

    const stored = try storage.storedHash(allocator, std.testing.io, "bucket/db/asset/one");
    try std.testing.expectEqualSlices(u8, &hash, stored.?);
    try std.testing.expectEqualStrings("ENABLED", client.inputs.items[0].HeadObjectCommand.ChecksumMode.?);
    try std.testing.expectEqualStrings("db/asset/one", client.inputs.items[0].HeadObjectCommand.Key);
}

test "storedHash is undefined for the composite checksum of a multipart upload" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var client: FakeClient = undefined;
    var storage = createStorage(allocator, &client, headWithCompositeChecksum);
    defer storage.s3.deinit();

    try std.testing.expect((try storage.storedHash(allocator, std.testing.io, "bucket/db/asset/one")) == null);
}

test "storedHash is undefined for an object that is not there" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var client: FakeClient = undefined;
    var storage = createStorage(allocator, &client, notFound);
    defer storage.s3.deinit();

    try std.testing.expect((try storage.storedHash(allocator, std.testing.io, "bucket/db/asset/one")) == null);
}

//
// Answers a HEAD with a checksum carrying characters outside the base64 alphabet.
//
fn headWithUntidyChecksum(commandName: []const u8) anyerror!S3CommandOutput {
    _ = commandName;
    return .{ .HeadObject = .{
        .ContentType = null,
        .ContentLength = 0,
        .LastModified = 0,
        .ChecksumSHA256 = "QU!J D",
    } };
}

//
// TypeScript decodes the checksum with `Buffer.from(checksum, "base64")`, which skips what is not base64 rather than
// failing.
//
test "storedHash decodes a checksum the way Buffer.from does, skipping characters that are not base64" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var client: FakeClient = undefined;
    var storage = createStorage(allocator, &client, headWithUntidyChecksum);
    defer storage.s3.deinit();

    const stored = try storage.storedHash(allocator, std.testing.io, "bucket/db/asset/one");
    try std.testing.expectEqualSlices(u8, "ABC", stored.?);
}

//
// The expected bytes are what Bun's `Buffer.from(text, "base64")` returns for each text.
//
test "bufferFromBase64 decodes like Buffer.from" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const bufferFromBase64 = storage_zig.cloud_storage.bufferFromBase64;
    try std.testing.expectEqualSlices(u8, "ABC", try bufferFromBase64(allocator, "QUJD"));
    try std.testing.expectEqualSlices(u8, "ABC", try bufferFromBase64(allocator, "QU!JD"));
    try std.testing.expectEqualSlices(u8, "A", try bufferFromBase64(allocator, "QU=JD"));
    try std.testing.expectEqualSlices(u8, "AB", try bufferFromBase64(allocator, "QUJ"));
    try std.testing.expectEqualSlices(u8, "", try bufferFromBase64(allocator, "Q"));
    try std.testing.expectEqualSlices(u8, "ABC", try bufferFromBase64(allocator, "QU JD"));
    try std.testing.expectEqualSlices(u8, &.{ 0x41, 0x4f, 0xbf }, try bufferFromBase64(allocator, "QU-_"));
}
