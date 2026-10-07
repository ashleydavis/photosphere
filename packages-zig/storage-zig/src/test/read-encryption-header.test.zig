const test_files = @import("test-files.zig");
const std = @import("std");
const storage_zig = @import("storage-zig");
const encryption = @import("encryption-zig");

const FileStorage = storage_zig.file_storage.FileStorage;
const readEncryptionHeader = storage_zig.read_encryption_header.readEncryptionHeader;
const readFirstBytes = storage_zig.read_encryption_header.readFirstBytes;
const ENCRYPTION_TAG = encryption.encryption_constants.ENCRYPTION_TAG;
const NEW_FORMAT_HEADER_LENGTH = encryption.encryption_constants.NEW_FORMAT_HEADER_LENGTH;
const PUBLIC_KEY_HASH_LENGTH = encryption.encryption_constants.PUBLIC_KEY_HASH_LENGTH;

const io = std.testing.io;

//
// The state shared by one test (TypeScript: a new MockStorage; Zig: FileStorage on a temporary directory).
//
const Fixture = struct {
    // Allocates everything the test creates.
    arena: std.heap.ArenaAllocator,

    // The temporary directory holding the file.
    tempDir: []const u8,

    // The storage the file is written to and read from.
    fileStorage: FileStorage,

    // The path of the file (TypeScript: "some/file.dat").
    filePath: []const u8,

    //
    // Creates the temporary directory and storage of a test.
    //
    fn init(self: *Fixture) !void {
        self.arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        const allocator = self.arena.allocator();
        self.tempDir = try test_files.makeTempDir(allocator, io, "read-encryption-header");
        self.fileStorage = FileStorage.init("fs:");
        self.filePath = try std.fmt.allocPrint(allocator, "{s}/some/file.dat", .{self.tempDir});
    }

    //
    // Deletes the temporary directory and frees the test's memory.
    //
    fn deinit(self: *Fixture) void {
        test_files.removeTempDir(io, self.tempDir);
        self.arena.deinit();
    }

    //
    // Writes the file (TypeScript: `storage.write(filePath, undefined, data)`).
    //
    fn write(self: *Fixture, data: []const u8) !void {
        try self.fileStorage.storage().write(self.arena.allocator(), io, self.filePath, null, data);
    }
};

test "readFirstBytes returns undefined when file does not exist" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    try std.testing.expect((try readFirstBytes(fixture.arena.allocator(), io, fixture.fileStorage.storage(), fixture.filePath, 10)) == null);
}

test "readFirstBytes returns undefined when file is empty" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    try fixture.write("");
    try std.testing.expect((try readFirstBytes(fixture.arena.allocator(), io, fixture.fileStorage.storage(), fixture.filePath, 10)) == null);
}

test "readFirstBytes returns full buffer when file is shorter than requested length" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const data = [_]u8{ 1, 2, 3 };
    try fixture.write(&data);
    const result = try readFirstBytes(fixture.arena.allocator(), io, fixture.fileStorage.storage(), fixture.filePath, 10);
    try std.testing.expect(result != null);
    try std.testing.expectEqualSlices(u8, &data, result.?);
}

test "readFirstBytes returns exactly length bytes when file is larger than requested length" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const data = [_]u8{0xab} ** 1000;
    try fixture.write(&data);
    const result = try readFirstBytes(fixture.arena.allocator(), io, fixture.fileStorage.storage(), fixture.filePath, 10);
    try std.testing.expect(result != null);
    try std.testing.expectEqual(@as(usize, 10), result.?.len);
    try std.testing.expectEqualSlices(u8, data[0..10], result.?);
}

test "readFirstBytes returns exactly length bytes for a large file" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const data = [_]u8{0xcd} ** 10_000;
    try fixture.write(&data);
    const result = try readFirstBytes(fixture.arena.allocator(), io, fixture.fileStorage.storage(), fixture.filePath, NEW_FORMAT_HEADER_LENGTH);
    try std.testing.expect(result != null);
    try std.testing.expectEqual(@as(usize, NEW_FORMAT_HEADER_LENGTH), result.?.len);
    try std.testing.expectEqualSlices(u8, data[0..NEW_FORMAT_HEADER_LENGTH], result.?);
}

test "readEncryptionHeader returns undefined when file does not exist" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    try std.testing.expect((try readEncryptionHeader(fixture.arena.allocator(), io, fixture.fileStorage.storage(), fixture.filePath)) == null);
}

test "readEncryptionHeader returns undefined when file is empty" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    try fixture.write("");
    try std.testing.expect((try readEncryptionHeader(fixture.arena.allocator(), io, fixture.fileStorage.storage(), fixture.filePath)) == null);
}

test "readEncryptionHeader returns undefined when file has fewer than 4 bytes" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    try fixture.write("PSE");
    try std.testing.expect((try readEncryptionHeader(fixture.arena.allocator(), io, fixture.fileStorage.storage(), fixture.filePath)) == null);
}

test "readEncryptionHeader returns undefined when file does not start with encryption tag" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var buf = [_]u8{0} ** NEW_FORMAT_HEADER_LENGTH;
    @memcpy(buf[0..4], "XXXX");
    try fixture.write(&buf);
    try std.testing.expect((try readEncryptionHeader(fixture.arena.allocator(), io, fixture.fileStorage.storage(), fixture.filePath)) == null);
}

test "readEncryptionHeader returns undefined when file has correct tag but length less than header length" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var buf = [_]u8{0} ** 20;
    @memcpy(buf[0..4], ENCRYPTION_TAG);
    try fixture.write(&buf);
    try std.testing.expect((try readEncryptionHeader(fixture.arena.allocator(), io, fixture.fileStorage.storage(), fixture.filePath)) == null);
}

test "readEncryptionHeader returns key hash buffer when file has valid new-format header" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const keyHash = [_]u8{0xab} ** PUBLIC_KEY_HASH_LENGTH;
    var header = [_]u8{0} ** NEW_FORMAT_HEADER_LENGTH;
    @memcpy(header[0..4], ENCRYPTION_TAG);
    @memcpy(header[12 .. 12 + PUBLIC_KEY_HASH_LENGTH], &keyHash);
    try fixture.write(&header);

    const result = try readEncryptionHeader(fixture.arena.allocator(), io, fixture.fileStorage.storage(), fixture.filePath);
    try std.testing.expect(result != null);
    try std.testing.expectEqual(@as(usize, PUBLIC_KEY_HASH_LENGTH), result.?.len);
    try std.testing.expectEqualSlices(u8, &keyHash, result.?);
}

test "readEncryptionHeader returns key hash when file is longer than header" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const keyHash = [_]u8{0xcd} ** PUBLIC_KEY_HASH_LENGTH;
    var fullFile = [_]u8{0} ** (NEW_FORMAT_HEADER_LENGTH + 100);
    @memcpy(fullFile[0..4], ENCRYPTION_TAG);
    @memcpy(fullFile[12 .. 12 + PUBLIC_KEY_HASH_LENGTH], &keyHash);
    try fixture.write(&fullFile);

    const result = try readEncryptionHeader(fixture.arena.allocator(), io, fixture.fileStorage.storage(), fixture.filePath);
    try std.testing.expect(result != null);
    try std.testing.expectEqual(@as(usize, PUBLIC_KEY_HASH_LENGTH), result.?.len);
    try std.testing.expectEqualSlices(u8, &keyHash, result.?);
}
