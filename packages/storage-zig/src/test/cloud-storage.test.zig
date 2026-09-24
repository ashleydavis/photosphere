const std = @import("std");
const storage_zig = @import("storage-zig");
const encryption = @import("encryption-zig");
const utils = @import("utils-zig");
const helpers = @import("test-helpers.zig");
const MockS3Server = @import("mock-s3-server.zig").MockS3Server;
const mock = @import("mock-s3-server.zig");

const CloudStorage = storage_zig.cloud_storage.CloudStorage;
const IS3Credentials = storage_zig.cloud_storage.IS3Credentials;
const createStorage = storage_zig.storage_factory.createStorage;

//
// The credentials of the mock server.
//
fn mockCredentials(allocator: std.mem.Allocator, server: *MockS3Server) !IS3Credentials {
    return .{
        .accessKeyId = mock.ACCESS_KEY_ID,
        .secretAccessKey = mock.SECRET_ACCESS_KEY,
        .region = mock.REGION,
        .endpoint = try server.endpoint(allocator),
    };
}

//
// Expects a list of names.
//
fn expectNames(expected: []const []const u8, actual: []const []const u8) !void {
    try std.testing.expectEqual(expected.len, actual.len);
    for (expected, actual) |expectedName, actualName| {
        try std.testing.expectEqualStrings(expectedName, actualName);
    }
}

test "parsePath splits the bucket and the key and rejects paths without both" {
    var cloudStorage = CloudStorage.init(std.testing.io, "s3:", null);
    defer cloudStorage.s3.deinit();
    const parsed = try cloudStorage.parsePath("bucket/some/key");
    try std.testing.expectEqualStrings("bucket", parsed.bucket);
    try std.testing.expectEqualStrings("some/key", parsed.key);
    try std.testing.expectError(error.Thrown, cloudStorage.parsePath("bucket"));
    try std.testing.expectEqualStrings("Invalid path: bucket. Expected <bucket-name>/<path>", utils.errors.lastErrorMessage());
    try std.testing.expectError(error.Thrown, cloudStorage.parsePath("bucket/"));
    try std.testing.expectEqualStrings("Invalid path: bucket/. Expected <bucket-name>/<path>", utils.errors.lastErrorMessage());
    try std.testing.expectError(error.Thrown, cloudStorage.parsePath("/key"));
}

test "CloudStorage writes, reads, gets info and checks existence against a mock S3 server" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const server = try MockS3Server.start(io);
    defer server.stop();
    var cloudStorage = CloudStorage.init(io, "s3:", try mockCredentials(allocator, server));
    defer cloudStorage.s3.deinit();
    const storage = cloudStorage.storage();

    try storage.write(allocator, io, "bucket/db/file.txt", "text/plain", "hello s3");
    try std.testing.expectEqualStrings("hello s3", (try server.getObject(allocator, "bucket/db/file.txt")).?);
    try std.testing.expectEqualStrings("text/plain", server.getContentType("bucket/db/file.txt").?);

    try std.testing.expectEqualStrings("hello s3", (try storage.read(allocator, io, "bucket/db/file.txt")).?);
    try std.testing.expectEqualStrings("hello s3", (try storage.read(allocator, io, "bucket//db/file.txt")).?);
    try std.testing.expect((try storage.read(allocator, io, "bucket/db/missing.txt")) == null);

    const fileInfo = (try storage.info(allocator, io, "bucket/db/file.txt")).?;
    try std.testing.expectEqual(@as(u64, 8), fileInfo.length);
    try std.testing.expectEqualStrings("text/plain", fileInfo.contentType.?);
    try std.testing.expectEqual(mock.LAST_MODIFIED_MS, fileInfo.lastModified);
    try std.testing.expect((try storage.info(allocator, io, "bucket/db/missing.txt")) == null);

    try std.testing.expect(try storage.fileExists(allocator, io, "bucket/db/file.txt"));
    try std.testing.expect(!try storage.fileExists(allocator, io, "bucket/db/missing.txt"));
    try std.testing.expect(try storage.dirExists(allocator, io, "bucket/db"));
    try std.testing.expect(try storage.dirExists(allocator, io, "bucket//db/"));
    try std.testing.expect(!try storage.dirExists(allocator, io, "bucket/other"));
    try std.testing.expectEqual(@as(u32, 0), server.signatureFailures);
}

test "CloudStorage lists files and directories with pagination like S3" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const server = try MockS3Server.start(io);
    defer server.stop();
    const objectPaths = [_][]const u8{ "bucket/db/a.txt", "bucket/db/b.txt", "bucket/db/c.txt", "bucket/db/asset/1", "bucket/db/display/1", "bucket/db/thumb/x/1", "bucket/root.txt" };
    for (objectPaths) |objectPath| {
        try server.putObject(objectPath, "x");
    }
    var cloudStorage = CloudStorage.init(io, "s3:", try mockCredentials(allocator, server));
    defer cloudStorage.s3.deinit();

    // MaxKeys counts common prefixes too (like S3), so a page can hold fewer file names than max.
    var fileNames: std.ArrayList([]const u8) = .empty;
    var next: ?[]const u8 = null;
    var pageCount: usize = 0;
    while (true) {
        const page = try cloudStorage.listFiles(allocator, io, "bucket/db", 2, next);
        try std.testing.expect(page.names.len <= 2);
        try fileNames.appendSlice(allocator, page.names);
        pageCount += 1;
        next = page.next;
        if (next == null) {
            break;
        }
    }
    try expectNames(&.{ "a.txt", "b.txt", "c.txt" }, fileNames.items);
    try std.testing.expectEqual(@as(usize, 3), pageCount);

    const dirs = try cloudStorage.listDirs(allocator, io, "bucket//db", 1000, null);
    try expectNames(&.{ "asset", "display", "thumb" }, dirs.names);
    try std.testing.expectError(error.Thrown, cloudStorage.listFiles(allocator, io, "bucket/", 1000, null));
    try expectNames(&.{"root.txt"}, (try cloudStorage.listFiles(allocator, io, "bucket//", 1000, null)).names);
    try expectNames(&.{"db"}, (try cloudStorage.listDirs(allocator, io, "bucket//", 1000, null)).names);
    try expectNames(&.{}, (try cloudStorage.listFiles(allocator, io, "bucket/missing", 1000, null)).names);

    try std.testing.expect(!try cloudStorage.isEmpty(allocator, io, "bucket/db"));
    try std.testing.expect(!try cloudStorage.isEmpty(allocator, io, "bucket/db/thumb"));
    try std.testing.expect(try cloudStorage.isEmpty(allocator, io, "bucket/missing"));
}

test "CloudStorage streams objects in and out, deletes files and directories and copies files" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const server = try MockS3Server.start(io);
    defer server.stop();
    var cloudStorage = CloudStorage.init(io, "s3:", try mockCredentials(allocator, server));
    defer cloudStorage.s3.deinit();

    const data = try helpers.makeData(allocator, 256 * 1024 + 3);
    var input = std.Io.Reader.fixed(data);
    try cloudStorage.writeStream(allocator, io, "bucket/db/asset/big", "image/jpeg", &input, null);
    try std.testing.expectEqualSlices(u8, data, (try server.getObject(allocator, "bucket/db/asset/big")).?);

    const stream = try cloudStorage.readStream(allocator, io, "bucket/db/asset/big");
    defer stream.destroy(io);
    try std.testing.expectEqualSlices(u8, data, try helpers.readAll(allocator, stream.reader()));

    try cloudStorage.copyTo(allocator, io, "bucket/db/asset/big", "bucket/copy/big copy");
    try std.testing.expectEqualSlices(u8, data, (try server.getObject(allocator, "bucket/copy/big copy")).?);

    try cloudStorage.deleteFile(allocator, io, "bucket/copy/big copy");
    try std.testing.expect(!try cloudStorage.fileExists(allocator, io, "bucket/copy/big copy"));
    try cloudStorage.deleteFile(allocator, io, "bucket/copy/missing");

    try server.putObject("bucket/db/asset/other", "x");
    try server.putObject("bucket/dbx/keep", "x");
    try cloudStorage.deleteDir(allocator, io, "bucket/db");
    try std.testing.expect(!try cloudStorage.dirExists(allocator, io, "bucket/db"));
    try std.testing.expect(try cloudStorage.fileExists(allocator, io, "bucket/dbx/keep"));
    try std.testing.expectEqual(@as(u32, 0), server.signatureFailures);
}

test "CloudStorage wraps S3 errors like TypeScript" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const server = try MockS3Server.start(io);
    defer server.stop();
    var credentials = try mockCredentials(allocator, server);
    credentials.secretAccessKey = "wrong";
    var cloudStorage = CloudStorage.init(io, "s3:", credentials);
    defer cloudStorage.s3.deinit();

    try std.testing.expectError(error.Thrown, cloudStorage.read(allocator, io, "bucket/file"));
    try std.testing.expectEqualStrings("Failed to read bucket/file: The request signature we calculated does not match the signature you provided.", utils.errors.lastErrorMessage());
    try std.testing.expectEqualStrings("WrappedError", utils.errors.lastErrorName());
    try std.testing.expectError(error.Thrown, cloudStorage.listFiles(allocator, io, "bucket/dir", 10, null));
    try std.testing.expectEqualStrings("Failed to list files in bucket/dir: The request signature we calculated does not match the signature you provided.", utils.errors.lastErrorMessage());
    try std.testing.expectError(error.Thrown, cloudStorage.listDirs(allocator, io, "bucket/dir", 10, null));
    try std.testing.expectEqualStrings("Failed to list directories in bucket/dir: The request signature we calculated does not match the signature you provided.", utils.errors.lastErrorMessage());
    try std.testing.expectError(error.Thrown, cloudStorage.fileExists(allocator, io, "bucket/file"));
    try std.testing.expectEqualStrings("Failed to check if file exists: Forbidden", utils.errors.lastErrorMessage());
    try std.testing.expectError(error.Thrown, cloudStorage.dirExists(allocator, io, "bucket/dir"));
    try std.testing.expectEqualStrings("Failed to check if directory exists: The request signature we calculated does not match the signature you provided.", utils.errors.lastErrorMessage());
    try std.testing.expectError(error.Thrown, cloudStorage.info(allocator, io, "bucket/file"));
    try std.testing.expectEqualStrings("Failed to get info for bucket/file: Forbidden", utils.errors.lastErrorMessage());
    try std.testing.expectError(error.Thrown, cloudStorage.write(allocator, io, "bucket/file", null, "x"));
    try std.testing.expectEqualStrings("Failed to write to bucket/file: The request signature we calculated does not match the signature you provided.", utils.errors.lastErrorMessage());
    var input = std.Io.Reader.fixed("x");
    try std.testing.expectError(error.Thrown, cloudStorage.writeStream(allocator, io, "bucket/file", null, &input, 1));
    try std.testing.expectEqualStrings("Failed to write stream to bucket/file: The request signature we calculated does not match the signature you provided.", utils.errors.lastErrorMessage());
    try std.testing.expectError(error.Thrown, cloudStorage.copyTo(allocator, io, "bucket/a", "bucket/b"));
    try std.testing.expectEqualStrings("Failed to copy from bucket/a to bucket/b: The request signature we calculated does not match the signature you provided.", utils.errors.lastErrorMessage());
}

test "CloudStorage reports a connection failure as the wrapped Zig error" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const server = try MockS3Server.start(io);
    const credentials = try mockCredentials(allocator, server);
    server.stop();
    var cloudStorage = CloudStorage.init(io, "s3:", credentials);
    defer cloudStorage.s3.deinit();
    try std.testing.expectError(error.Thrown, cloudStorage.read(allocator, io, "bucket/file"));
    try std.testing.expectEqualStrings("Failed to read bucket/file: ConnectionRefused", utils.errors.lastErrorMessage());
}

test "createStorage with an s3: path uses CloudStorage under the path prefix, with and without encryption" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const server = try MockS3Server.start(io);
    defer server.stop();

    const plainStorage = try createStorage(allocator, io, "s3:bucket/photos", try mockCredentials(allocator, server), null);
    try plainStorage.storage.write(allocator, io, "README.md", null, "readme");
    try std.testing.expectEqualStrings("readme", (try server.getObject(allocator, "bucket/photos/README.md")).?);
    try expectNames(&.{"README.md"}, (try plainStorage.storage.listFiles(allocator, io, "", 1000, null)).names);

    const privateKeyPem = try std.Io.Dir.cwd().readFileAlloc(io, "../encryption-zig/src/test/fixtures/ts-private.pem", allocator, .unlimited);
    const publicKeyPem = try std.Io.Dir.cwd().readFileAlloc(io, "../encryption-zig/src/test/fixtures/ts-public.pem", allocator, .unlimited);
    const loaded = try encryption.key_utils.loadEncryptionKeysFromPem(allocator, &.{.{ .privateKeyPem = privateKeyPem, .publicKeyPem = publicKeyPem }});
    const encrypted = try createStorage(allocator, io, "s3:bucket/photos", try mockCredentials(allocator, server), loaded.options);
    try std.testing.expectEqualStrings("encrypted-s3", encrypted.@"type");
    const data = try helpers.makeData(allocator, 5000);
    var input = std.Io.Reader.fixed(data);
    try encrypted.storage.writeStream(allocator, io, "asset/1", null, &input, data.len);
    const raw = (try server.getObject(allocator, "bucket/photos/asset/1")).?;
    try std.testing.expectEqualStrings("PSEN", raw[0..4]);
    try std.testing.expectEqual(@as(u64, raw.len), (try encrypted.storage.info(allocator, io, "asset/1")).?.length);
    const stream = try encrypted.storage.readStream(allocator, io, "asset/1");
    defer stream.destroy(io);
    try std.testing.expectEqualSlices(u8, data, try helpers.readAll(allocator, stream.reader()));
    try std.testing.expectEqualSlices(u8, raw, (try encrypted.rawStorage.read(allocator, io, "asset/1")).?);
}
