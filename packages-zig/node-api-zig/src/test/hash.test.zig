const std = @import("std");
const utils = @import("utils-zig");
const node_api = @import("node-api-zig");
const helpers = @import("test-helpers.zig");
const hash = node_api.hash;
const Sha256 = std.crypto.hash.sha2.Sha256;

test "computeHash returns the sha256 of the stream" {
    var reader = std.Io.Reader.fixed("hello world");
    const digest = try hash.computeHash(&reader);
    var expected: [32]u8 = undefined;
    Sha256.hash("hello world", &expected, .{});
    try std.testing.expectEqualSlices(u8, &expected, &digest);
}

test "computeHash of an empty stream is the sha256 of nothing" {
    var reader = std.Io.Reader.fixed("");
    const digest = try hash.computeHash(&reader);
    try std.testing.expectEqualStrings("e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", &std.fmt.bytesToHex(digest, .lower));
}

test "computeHash hashes streams larger than its buffer" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const data = try arena.allocator().alloc(u8, 300 * 1024 + 17);
    for (data, 0..) |*byte, index| {
        byte.* = @truncate(index *% 31 +% 7);
    }
    var reader = std.Io.Reader.fixed(data);
    const digest = try hash.computeHash(&reader);
    var expected: [32]u8 = undefined;
    Sha256.hash(data, &expected, .{});
    try std.testing.expectEqualSlices(u8, &expected, &digest);
}

test "computeAssetHash returns the hash with the length and date of the file stat" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var reader = std.Io.Reader.fixed("abc");
    const hashed = try hash.computeAssetHash(arena.allocator(), &reader, .{ .length = 3, .lastModified = 1234 });
    try std.testing.expectEqualStrings("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", &std.fmt.bytesToHex(hashed.hash[0..32].*, .lower));
    try std.testing.expectEqual(@as(u64, 3), hashed.length);
    try std.testing.expectEqual(@as(i64, 1234), hashed.lastModified);
}

//
// A directory that lives for the length of the test, holding the files that get hashed.
//
fn writeTestFile(allocator: std.mem.Allocator, io: std.Io, workingDir: []const u8, name: []const u8, contents: []const u8) ![]const u8 {
    const filePath = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ workingDir, name });
    try helpers.writeFile(io, filePath, contents);
    return filePath;
}

//
// The state of the native hasher stand-ins of the tests below.
//
const NativeHasherStandIn = struct {
    // What the hasher answers.
    answer: []const u8,

    // The path it was asked for.
    askedFor: ?[]const u8 = null,

    //
    // Records the path and answers.
    //
    fn hashFile(context: ?*anyopaque, allocator: std.mem.Allocator, filePath: []const u8) anyerror![]const u8 {
        const self: *NativeHasherStandIn = @ptrCast(@alignCast(context.?));
        self.askedFor = try allocator.dupe(u8, filePath);
        return allocator.dupe(u8, self.answer);
    }
};

test "there is no native file hasher when crypto is Node's own" {
    // Which is every platform except the mobile worker. There the bundler resolves `crypto` to
    // the mobile shim, which does export one; nothing else does, so the import path is what
    // answers the question and no platform check is written anywhere.
    try std.testing.expect(hash.getNativeFileHasher() == null);
}

test "streams the file through a JS hash when no native hasher is handed in" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const workingDir = try helpers.makeTempDir(allocator, io, "photosphere-hash-test");
    defer helpers.removeTempDir(io, workingDir);
    const contents = "the quick brown fox";
    const filePath = try writeTestFile(allocator, io, workingDir, "streamed.bin", contents);

    var expected: [32]u8 = undefined;
    Sha256.hash(contents, &expected, .{});
    try std.testing.expectEqualSlices(u8, &expected, try hash.computeFileHash(allocator, io, filePath, null));
}

test "uses the native hasher when one is handed in, and hands it the file's path" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const workingDir = try helpers.makeTempDir(allocator, io, "photosphere-hash-test");
    defer helpers.removeTempDir(io, workingDir);
    const filePath = try writeTestFile(allocator, io, workingDir, "native.bin", "the quick brown fox");

    // Deliberately answers something the streaming path could never produce, so the test can
    // tell which path ran rather than assuming it from the digest coming out right.
    const sentinel = [_]u8{0xab} ** 32;
    var standIn: NativeHasherStandIn = .{
        .answer = &sentinel,
    };

    const digest = try hash.computeFileHash(allocator, io, filePath, .{
        .context = &standIn,
        .function = NativeHasherStandIn.hashFile,
    });

    try std.testing.expectEqualSlices(u8, &sentinel, digest);
    try std.testing.expectEqualStrings(filePath, standIn.askedFor.?);
}

test "the native path and the streaming path agree on the same bytes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const workingDir = try helpers.makeTempDir(allocator, io, "photosphere-hash-test");
    defer helpers.removeTempDir(io, workingDir);
    // The one property that is not negotiable. These digests are the identity of every asset and
    // the key of the hash cache, so a native hash differing from the streamed one by a byte
    // would make every database already written look wrong, and silently: photos would
    // re-import and the cache would never hit.
    const contents = try allocator.alloc(u8, 3 * 1024 * 1024);
    for (contents, 0..) |*byte, index| {
        byte.* = @intCast(index % 251);
    }
    const filePath = try writeTestFile(allocator, io, workingDir, "agreement.bin", contents);

    const streamed = try hash.computeFileHash(allocator, io, filePath, null);

    // Stands in for the platform hash: the same algorithm over the same bytes.
    var platformDigest: [32]u8 = undefined;
    Sha256.hash(contents, &platformDigest, .{});
    var standIn: NativeHasherStandIn = .{
        .answer = &platformDigest,
    };
    const nativelyHashed = try hash.computeFileHash(allocator, io, filePath, .{
        .context = &standIn,
        .function = NativeHasherStandIn.hashFile,
    });

    try std.testing.expectEqualSlices(u8, streamed, nativelyHashed);
}

test "hashes an empty file the same way down both paths" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const workingDir = try helpers.makeTempDir(allocator, io, "photosphere-hash-test");
    defer helpers.removeTempDir(io, workingDir);
    const filePath = try writeTestFile(allocator, io, workingDir, "empty.bin", "");

    const streamed = try hash.computeFileHash(allocator, io, filePath, null);
    var emptyDigest: [32]u8 = undefined;
    Sha256.hash("", &emptyDigest, .{});
    try std.testing.expectEqualSlices(u8, &emptyDigest, streamed);

    var standIn: NativeHasherStandIn = .{
        .answer = &emptyDigest,
    };
    const nativelyHashed = try hash.computeFileHash(allocator, io, filePath, .{
        .context = &standIn,
        .function = NativeHasherStandIn.hashFile,
    });
    try std.testing.expectEqualSlices(u8, streamed, nativelyHashed);
}

test "computeFileHash reports a missing file the way Node does" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    try std.testing.expectError(error.Thrown, hash.computeFileHash(allocator, io, "no-such-dir/no-such-file.bin", null));
    try std.testing.expectEqualStrings("ENOENT: no such file or directory, open 'no-such-dir/no-such-file.bin'", utils.errors.lastErrorMessage());
}

test "getHashFromCache answers from an entry whose length and date match the file, with the file's own stat" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const cacheDir = try helpers.makeTempDir(allocator, io, "hash-from-cache");
    defer helpers.removeTempDir(io, cacheDir);
    var cache = try node_api.hash_cache.HashCache.init(cacheDir, false);
    defer cache.deinit();
    _ = try cache.load(io);
    const digest = [_]u8{0x11} ** 32;
    try cache.addHash("/photos/a.jpg", .{
        .hash = &digest,
        .length = 10,
        .lastModified = 5000,
    });

    const hit = (try hash.getHashFromCache(allocator, "/photos/a.jpg", .{ .length = 10, .lastModified = 5000 }, &cache, null)).?;
    try std.testing.expectEqualSlices(u8, &digest, hit.hash);
    try std.testing.expectEqual(@as(u64, 10), hit.length);
    try std.testing.expectEqual(@as(i64, 5000), hit.lastModified);

    // A file that has changed size or date since it was hashed is not answered from the cache.
    try std.testing.expect(try hash.getHashFromCache(allocator, "/photos/a.jpg", .{ .length = 11, .lastModified = 5000 }, &cache, null) == null);
    try std.testing.expect(try hash.getHashFromCache(allocator, "/photos/a.jpg", .{ .length = 10, .lastModified = 5001 }, &cache, null) == null);
    try std.testing.expect(try hash.getHashFromCache(allocator, "/photos/other.jpg", .{ .length = 10, .lastModified = 5000 }, &cache, null) == null);
}

test "getHashFromCache looks an item up under its identity and compares against the identity" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const cacheDir = try helpers.makeTempDir(allocator, io, "hash-from-cache-identity");
    defer helpers.removeTempDir(io, cacheDir);
    var cache = try node_api.hash_cache.HashCache.init(cacheDir, false);
    defer cache.deinit();
    _ = try cache.load(io);
    const digest = [_]u8{0x22} ** 32;
    try cache.addSourceHash("library-item-1", .{
        .hash = &digest,
        .length = 99,
        .lastModified = 7000,
    });

    // The temporary copy has its own path and a modified time minted by the copy: neither matters.
    const hit = (try hash.getHashFromCache(allocator, "/tmp/copy.jpg", .{ .length = 99, .lastModified = 123456 }, &cache, .{
        .key = "library-item-1",
        .length = 99,
        .lastModified = 7000,
    })).?;
    try std.testing.expectEqualSlices(u8, &digest, hit.hash);
    try std.testing.expectEqual(@as(i64, 123456), hit.lastModified);

    try std.testing.expect(try hash.getHashFromCache(allocator, "/tmp/copy.jpg", .{ .length = 99, .lastModified = 7000 }, &cache, .{
        .key = "library-item-1",
        .length = 98,
        .lastModified = 7000,
    }) == null);
}

test "validateAndHash hashes a valid image" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    _ = try helpers.setupEnvironment(io);
    const contents = try helpers.readFile(allocator, io, "../../test/test.png");

    const hashed = (try hash.validateAndHash(allocator, io, "../../test/test.png", .{ .length = contents.len, .lastModified = 42 }, "image/png", "test.png")).?;

    var expected: [32]u8 = undefined;
    Sha256.hash(contents, &expected, .{});
    try std.testing.expectEqualSlices(u8, &expected, hashed.hash);
    try std.testing.expectEqual(@as(u64, contents.len), hashed.length);
    try std.testing.expectEqual(@as(i64, 42), hashed.lastModified);
}

test "validateAndHash returns undefined for a file that fails its validation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    _ = try helpers.setupEnvironment(io);
    const workingDir = try helpers.makeTempDir(allocator, io, "validate-and-hash");
    defer helpers.removeTempDir(io, workingDir);
    const filePath = try writeTestFile(allocator, io, workingDir, "broken.png", "this is not a png");

    try std.testing.expect(try hash.validateAndHash(allocator, io, filePath, .{ .length = 17, .lastModified = 42 }, "image/png", "broken.png") == null);
}
