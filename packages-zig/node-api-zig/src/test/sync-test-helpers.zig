const std = @import("std");
const utils = @import("utils-zig");
const node_utils = @import("node-utils-zig");
const merkle_tree_zig = @import("merkle-tree-zig");
const storage_zig = @import("storage-zig");
const serialization_zig = @import("serialization-zig");
const bdb = @import("bdb-zig");
const storage_module = storage_zig.storage;
const merkle_tree = merkle_tree_zig.merkle_tree;
const IStorage = storage_module.IStorage;
const IReadStream = storage_module.IReadStream;
const IFileInfo = storage_module.IFileInfo;
const IListResult = storage_module.IListResult;
const IWriteLockInfo = storage_module.IWriteLockInfo;
const BsonDocument = serialization_zig.bson.BsonDocument;
const BsonValue = serialization_zig.bson.BsonValue;
const BsonDatabase = bdb.database.BsonDatabase;
const Sha256 = std.crypto.hash.sha2.Sha256;

//
// Helpers shared by the sync test files (the helpers each TypeScript sync test file defines for itself, and the
// storage subclasses they make of MockStorage).
//

//
// The database's own hash of some contents (TypeScript: `createHash("sha256").update(contents).digest()`).
//
pub fn hashOf(allocator: std.mem.Allocator, contents: []const u8) ![]const u8 {
    const digest = try allocator.create([Sha256.digest_length]u8);
    Sha256.hash(contents, digest, .{});
    return digest;
}

//
// A file to put in a database: its name and its contents.
//
pub const IFileToStore = struct {
    // Where the file lives.
    name: []const u8,

    // What it holds.
    contents: []const u8,
};

//
// Fills a storage with the given files and a merkle tree describing exactly them, under the length of each file's
// contents, recording the given asset ids as deleted (none when empty). The tree is saved to `.db/files.dat`.
// (TypeScript: the makeDatabase, makeDatabaseWithDeletions and fillDatabase functions of the sync tests.)
//
pub fn fillDatabase(allocator: std.mem.Allocator, io: std.Io, storage: IStorage, databaseId: []const u8, files: []const IFileToStore, deletedAssetIds: []const []const u8) !void {
    var tree = merkle_tree.createTree(databaseId);
    for (files) |file| {
        try storage.write(allocator, io, file.name, "image/jpeg", file.contents);
        tree = try merkle_tree.addItem(allocator, &tree, .{
            .name = file.name,
            .hash = try hashOf(allocator, file.contents),
            .length = file.contents.len,
            .lastModified = 1767225600000, // 2026-01-01T00:00:00.000Z
        });
    }
    var databaseMetadata: BsonDocument = .empty;
    try databaseMetadata.put(allocator, "filesImported", .{ .number = @floatFromInt(files.len) });
    if (deletedAssetIds.len > 0) {
        const deleted = try allocator.alloc(BsonValue, deletedAssetIds.len);
        for (deletedAssetIds, 0..) |assetId, index| {
            deleted[index] = .{ .string = assetId };
        }
        try databaseMetadata.put(allocator, "deletedAssetIds", .{ .array = deleted });
    }
    tree.databaseMetadata = databaseMetadata;
    tree.merkle = try merkle_tree.buildMerkleTree(allocator, tree.sort);
    tree.dirty = false;
    try merkle_tree.saveTree(allocator, io, ".db/files.dat", &tree, storage, "FTRE");
}

//
// Files named after themselves: each file holds its own name (TypeScript: `Buffer.from(fileName, "utf-8")`).
//
pub fn filesNamed(allocator: std.mem.Allocator, fileNames: []const []const u8) ![]const IFileToStore {
    const files = try allocator.alloc(IFileToStore, fileNames.len);
    for (fileNames, 0..) |fileName, index| {
        files[index] = .{
            .name = fileName,
            .contents = fileName,
        };
    }
    return files;
}

//
// A bson database for a push to flush, commit and remove deleted assets' records from (TypeScript: the
// makeBsonDatabase stand-in; Zig: a real BsonDatabase over its own empty store, as pushFiles takes a BsonDatabase).
//
pub fn makeBsonDatabase(allocator: std.mem.Allocator, storage: IStorage) !*BsonDatabase {
    const uuidGenerator = try allocator.create(node_utils.test_uuid_generator.TestUuidGenerator);
    uuidGenerator.* = try node_utils.test_uuid_generator.TestUuidGenerator.init(allocator);
    const timestampProvider = try allocator.create(node_utils.test_timestamp_provider.TestTimestampProvider);
    timestampProvider.* = .{};
    return BsonDatabase.init(allocator, storage, ".db/bson", uuidGenerator.uuidGenerator(), timestampProvider.timestampProvider());
}

//
// What a test wrote to stdout and stderr (the test runner talks to the build over stdout, so the log is captured).
//
pub const Capture = struct {
    // What was written to stdout.
    stdout: std.Io.Writer.Allocating,

    // What was written to stderr.
    stderr: std.Io.Writer.Allocating,

    //
    // Starts capturing the console.
    //
    pub fn start(self: *Capture, allocator: std.mem.Allocator) void {
        self.stdout = .init(allocator);
        self.stderr = .init(allocator);
        utils.console.setCapture(&self.stdout.writer, &self.stderr.writer);
    }

    //
    // Stops capturing the console, discarding stdout again as the test environment does.
    //
    pub fn stop(self: *Capture) void {
        _ = self;
        utils.console.setCapture(&discarded_stdout.writer, null);
    }

    //
    // The lines written to stdout that start with the prefix.
    //
    pub fn linesStartingWith(self: *Capture, allocator: std.mem.Allocator, prefix: []const u8) ![]const []const u8 {
        var lines: std.ArrayList([]const u8) = .empty;
        var iterator = std.mem.splitScalar(u8, self.stdout.written(), '\n');
        while (iterator.next()) |line| {
            if (std.mem.startsWith(u8, line, prefix)) {
                try lines.append(allocator, line);
            }
        }
        return lines.items;
    }
};

//
// Receives stdout once a capture stops.
//
var discarded_stdout: std.Io.Writer.Discarding = .init(&.{});

//
// A storage that throws if any of it is used (TypeScript: the throwingProxy of sync-early-out.test.ts).
//
pub const ThrowingStorage = struct {
    // Names the storage in the error.
    label: []const u8,

    //
    // Gets the IStorage interface.
    //
    pub fn storage(self: *ThrowingStorage) IStorage {
        return .{ .ptr = self, .vtable = storage_module.implement(ThrowingStorage), .location = "throwing:" };
    }

    //
    // Throws for any access.
    //
    fn unexpected(self: *ThrowingStorage) anyerror {
        return utils.errors.throwError("unexpected access to {s}", .{self.label});
    }

    //
    // Throws.
    //
    pub fn isEmpty(self: *ThrowingStorage, allocator: std.mem.Allocator, io: std.Io, path: []const u8) !bool {
        _ = allocator;
        _ = io;
        _ = path;
        return self.unexpected();
    }

    //
    // Throws.
    //
    pub fn listFiles(self: *ThrowingStorage, allocator: std.mem.Allocator, io: std.Io, path: []const u8, max: u32, next: ?[]const u8) !IListResult {
        _ = allocator;
        _ = io;
        _ = path;
        _ = max;
        _ = next;
        return self.unexpected();
    }

    //
    // Throws.
    //
    pub fn listDirs(self: *ThrowingStorage, allocator: std.mem.Allocator, io: std.Io, path: []const u8, max: u32, next: ?[]const u8) !IListResult {
        _ = allocator;
        _ = io;
        _ = path;
        _ = max;
        _ = next;
        return self.unexpected();
    }

    //
    // Throws.
    //
    pub fn fileExists(self: *ThrowingStorage, allocator: std.mem.Allocator, io: std.Io, filePath: []const u8) !bool {
        _ = allocator;
        _ = io;
        _ = filePath;
        return self.unexpected();
    }

    //
    // Throws.
    //
    pub fn dirExists(self: *ThrowingStorage, allocator: std.mem.Allocator, io: std.Io, dirPath: []const u8) !bool {
        _ = allocator;
        _ = io;
        _ = dirPath;
        return self.unexpected();
    }

    //
    // Says nothing (it cannot throw), which no sync step asks of the storages under test here.
    //
    pub fn readableLength(self: *ThrowingStorage, fileInfo: IFileInfo) ?u64 {
        _ = self;
        _ = fileInfo;
        return null;
    }

    //
    // Throws.
    //
    pub fn writeStreamHashed(self: *ThrowingStorage, allocator: std.mem.Allocator, io: std.Io, filePath: []const u8, contentType: ?[]const u8, inputStream: *std.Io.Reader, contentLength: ?u64, sha256: []const u8) !bool {
        _ = allocator;
        _ = io;
        _ = filePath;
        _ = contentType;
        _ = inputStream;
        _ = contentLength;
        _ = sha256;
        return self.unexpected();
    }

    //
    // Throws.
    //
    pub fn storedHash(self: *ThrowingStorage, allocator: std.mem.Allocator, io: std.Io, filePath: []const u8) !?[]const u8 {
        _ = allocator;
        _ = io;
        _ = filePath;
        return self.unexpected();
    }

    //
    // Throws.
    //
    pub fn info(self: *ThrowingStorage, allocator: std.mem.Allocator, io: std.Io, filePath: []const u8) !?IFileInfo {
        _ = allocator;
        _ = io;
        _ = filePath;
        return self.unexpected();
    }

    //
    // Throws.
    //
    pub fn read(self: *ThrowingStorage, allocator: std.mem.Allocator, io: std.Io, filePath: []const u8) !?[]u8 {
        _ = allocator;
        _ = io;
        _ = filePath;
        return self.unexpected();
    }

    //
    // Throws.
    //
    pub fn write(self: *ThrowingStorage, allocator: std.mem.Allocator, io: std.Io, filePath: []const u8, contentType: ?[]const u8, data: []const u8) !void {
        _ = allocator;
        _ = io;
        _ = filePath;
        _ = contentType;
        _ = data;
        return self.unexpected();
    }

    //
    // Throws.
    //
    pub fn readStream(self: *ThrowingStorage, allocator: std.mem.Allocator, io: std.Io, filePath: []const u8) !IReadStream {
        _ = allocator;
        _ = io;
        _ = filePath;
        return self.unexpected();
    }

    //
    // Throws.
    //
    pub fn writeStream(self: *ThrowingStorage, allocator: std.mem.Allocator, io: std.Io, filePath: []const u8, contentType: ?[]const u8, inputStream: *std.Io.Reader, contentLength: ?u64) !void {
        _ = allocator;
        _ = io;
        _ = filePath;
        _ = contentType;
        _ = inputStream;
        _ = contentLength;
        return self.unexpected();
    }

    //
    // Throws.
    //
    pub fn deleteFile(self: *ThrowingStorage, allocator: std.mem.Allocator, io: std.Io, filePath: []const u8) !void {
        _ = allocator;
        _ = io;
        _ = filePath;
        return self.unexpected();
    }

    //
    // Throws.
    //
    pub fn deleteDir(self: *ThrowingStorage, allocator: std.mem.Allocator, io: std.Io, dirPath: []const u8) !void {
        _ = allocator;
        _ = io;
        _ = dirPath;
        return self.unexpected();
    }

    //
    // Throws.
    //
    pub fn copyTo(self: *ThrowingStorage, allocator: std.mem.Allocator, io: std.Io, srcPath: []const u8, destPath: []const u8) !void {
        _ = allocator;
        _ = io;
        _ = srcPath;
        _ = destPath;
        return self.unexpected();
    }

    //
    // Throws.
    //
    pub fn checkWriteLock(self: *ThrowingStorage, allocator: std.mem.Allocator, io: std.Io, filePath: []const u8) !?IWriteLockInfo {
        _ = allocator;
        _ = io;
        _ = filePath;
        return self.unexpected();
    }

    //
    // Throws.
    //
    pub fn acquireWriteLock(self: *ThrowingStorage, allocator: std.mem.Allocator, io: std.Io, filePath: []const u8, owner: []const u8) !bool {
        _ = allocator;
        _ = io;
        _ = filePath;
        _ = owner;
        return self.unexpected();
    }

    //
    // Throws.
    //
    pub fn releaseWriteLock(self: *ThrowingStorage, allocator: std.mem.Allocator, io: std.Io, filePath: []const u8) !void {
        _ = allocator;
        _ = io;
        _ = filePath;
        return self.unexpected();
    }
};

//
// A storage that passes every call through to another and watches what the sync does with it. Each field turns on
// what one of the TypeScript sync tests' storages does:
//   - infoLengthOverhead and readableLengthUnknown: CannotSayHowLongItReadsStorage (sync-encrypted-lengths).
//   - declaredLengths: LengthRecordingStorage (sync-encrypted-lengths).
//   - treeWrites: countTreeWrites (sync-tree-saves).
//   - hashes, readStreamPaths, verifiesWhatItWrites, askedAbout and hashesWrittenWith: HashReportingStorage
//     (sync-verification).
//
pub const SpyStorage = struct {
    // Allocates what is recorded.
    allocator: std.mem.Allocator,

    // The storage every call is passed through to.
    inner: IStorage,

    // Added to the length info reports (the encryption's overhead of an encrypted store).
    infoLengthOverhead: u64 = 0,

    // True when readableLength says it cannot say, as encrypted storage does.
    readableLengthUnknown: bool = false,

    // The length declared for each file written with writeStreamHashed, by file name. Null for a write that
    // declared none.
    declaredLengths: std.StringArrayHashMapUnmanaged(?u64) = .empty,

    // The number of writes of the merkle tree.
    treeWrites: u32 = 0,

    // What storedHash answers, by path, when set; a path that is not there answers undefined. When null storedHash
    // is passed through.
    hashes: ?*const std.StringHashMapUnmanaged([]const u8) = null,

    // The paths that were streamed back out, in order.
    readStreamPaths: std.ArrayList([]const u8) = .empty,

    // What writeStreamHashed reports, when set; when null it reports what the storage underneath does.
    verifiesWhatItWrites: ?bool = null,

    // The paths info() and storedHash() were asked about.
    askedAbout: std.ArrayList([]const u8) = .empty,

    // The hashes handed to writeStreamHashed, by path.
    hashesWrittenWith: std.StringArrayHashMapUnmanaged([]const u8) = .empty,

    //
    // Gets the IStorage interface.
    //
    pub fn storage(self: *SpyStorage) IStorage {
        return .{ .ptr = self, .vtable = storage_module.implement(SpyStorage), .location = self.inner.location };
    }

    //
    // Passes isEmpty through.
    //
    pub fn isEmpty(self: *SpyStorage, allocator: std.mem.Allocator, io: std.Io, path: []const u8) !bool {
        return self.inner.isEmpty(allocator, io, path);
    }

    //
    // Passes listFiles through.
    //
    pub fn listFiles(self: *SpyStorage, allocator: std.mem.Allocator, io: std.Io, path: []const u8, max: u32, next: ?[]const u8) !IListResult {
        return self.inner.listFiles(allocator, io, path, max, next);
    }

    //
    // Passes listDirs through.
    //
    pub fn listDirs(self: *SpyStorage, allocator: std.mem.Allocator, io: std.Io, path: []const u8, max: u32, next: ?[]const u8) !IListResult {
        return self.inner.listDirs(allocator, io, path, max, next);
    }

    //
    // Passes fileExists through.
    //
    pub fn fileExists(self: *SpyStorage, allocator: std.mem.Allocator, io: std.Io, filePath: []const u8) !bool {
        return self.inner.fileExists(allocator, io, filePath);
    }

    //
    // Passes dirExists through.
    //
    pub fn dirExists(self: *SpyStorage, allocator: std.mem.Allocator, io: std.Io, dirPath: []const u8) !bool {
        return self.inner.dirExists(allocator, io, dirPath);
    }

    //
    // Unknowable when readableLengthUnknown is set, otherwise passed through.
    //
    pub fn readableLength(self: *SpyStorage, fileInfo: IFileInfo) ?u64 {
        if (self.readableLengthUnknown) {
            return null;
        }
        return self.inner.readableLength(fileInfo);
    }

    //
    // Records the declared length and the hash, then passes the write through.
    //
    pub fn writeStreamHashed(self: *SpyStorage, allocator: std.mem.Allocator, io: std.Io, filePath: []const u8, contentType: ?[]const u8, inputStream: *std.Io.Reader, contentLength: ?u64, sha256: []const u8) !bool {
        const ownedPath = try self.allocator.dupe(u8, filePath);
        try self.declaredLengths.put(self.allocator, ownedPath, contentLength);
        try self.hashesWrittenWith.put(self.allocator, ownedPath, try self.allocator.dupe(u8, sha256));
        const verified = try self.inner.writeStreamHashed(allocator, io, filePath, contentType, inputStream, contentLength, sha256);
        return self.verifiesWhatItWrites orelse verified;
    }

    //
    // Records the question, then answers from hashes when set or passes it through.
    //
    pub fn storedHash(self: *SpyStorage, allocator: std.mem.Allocator, io: std.Io, filePath: []const u8) !?[]const u8 {
        try self.askedAbout.append(self.allocator, try self.allocator.dupe(u8, filePath));
        if (self.hashes) |hashes| {
            return hashes.get(filePath);
        }
        return self.inner.storedHash(allocator, io, filePath);
    }

    //
    // Records the question, then passes it through with the overhead added to the length.
    //
    pub fn info(self: *SpyStorage, allocator: std.mem.Allocator, io: std.Io, filePath: []const u8) !?IFileInfo {
        try self.askedAbout.append(self.allocator, try self.allocator.dupe(u8, filePath));
        var fileInfo = try self.inner.info(allocator, io, filePath) orelse {
            return null;
        };
        fileInfo.length += self.infoLengthOverhead;
        return fileInfo;
    }

    //
    // Passes read through.
    //
    pub fn read(self: *SpyStorage, allocator: std.mem.Allocator, io: std.Io, filePath: []const u8) !?[]u8 {
        return self.inner.read(allocator, io, filePath);
    }

    //
    // Counts writes of the merkle tree, then passes the write through.
    //
    pub fn write(self: *SpyStorage, allocator: std.mem.Allocator, io: std.Io, filePath: []const u8, contentType: ?[]const u8, data: []const u8) !void {
        if (std.mem.eql(u8, filePath, ".db/files.dat")) {
            self.treeWrites += 1;
        }
        return self.inner.write(allocator, io, filePath, contentType, data);
    }

    //
    // Records the path, then passes readStream through.
    //
    pub fn readStream(self: *SpyStorage, allocator: std.mem.Allocator, io: std.Io, filePath: []const u8) !IReadStream {
        try self.readStreamPaths.append(self.allocator, try self.allocator.dupe(u8, filePath));
        return self.inner.readStream(allocator, io, filePath);
    }

    //
    // Passes writeStream through.
    //
    pub fn writeStream(self: *SpyStorage, allocator: std.mem.Allocator, io: std.Io, filePath: []const u8, contentType: ?[]const u8, inputStream: *std.Io.Reader, contentLength: ?u64) !void {
        return self.inner.writeStream(allocator, io, filePath, contentType, inputStream, contentLength);
    }

    //
    // Passes deleteFile through.
    //
    pub fn deleteFile(self: *SpyStorage, allocator: std.mem.Allocator, io: std.Io, filePath: []const u8) !void {
        return self.inner.deleteFile(allocator, io, filePath);
    }

    //
    // Passes deleteDir through.
    //
    pub fn deleteDir(self: *SpyStorage, allocator: std.mem.Allocator, io: std.Io, dirPath: []const u8) !void {
        return self.inner.deleteDir(allocator, io, dirPath);
    }

    //
    // Passes copyTo through.
    //
    pub fn copyTo(self: *SpyStorage, allocator: std.mem.Allocator, io: std.Io, srcPath: []const u8, destPath: []const u8) !void {
        return self.inner.copyTo(allocator, io, srcPath, destPath);
    }

    //
    // Passes checkWriteLock through.
    //
    pub fn checkWriteLock(self: *SpyStorage, allocator: std.mem.Allocator, io: std.Io, filePath: []const u8) !?IWriteLockInfo {
        return self.inner.checkWriteLock(allocator, io, filePath);
    }

    //
    // Passes acquireWriteLock through.
    //
    pub fn acquireWriteLock(self: *SpyStorage, allocator: std.mem.Allocator, io: std.Io, filePath: []const u8, owner: []const u8) !bool {
        return self.inner.acquireWriteLock(allocator, io, filePath, owner);
    }

    //
    // Passes releaseWriteLock through.
    //
    pub fn releaseWriteLock(self: *SpyStorage, allocator: std.mem.Allocator, io: std.Io, filePath: []const u8) !void {
        return self.inner.releaseWriteLock(allocator, io, filePath);
    }

    //
    // True when the path was streamed back out.
    //
    pub fn wasReadBack(self: *const SpyStorage, filePath: []const u8) bool {
        for (self.readStreamPaths.items) |path| {
            if (std.mem.eql(u8, path, filePath)) {
                return true;
            }
        }
        return false;
    }

    //
    // True when info() or storedHash() was asked about the path.
    //
    pub fn wasAskedAbout(self: *const SpyStorage, filePath: []const u8) bool {
        for (self.askedAbout.items) |path| {
            if (std.mem.eql(u8, path, filePath)) {
                return true;
            }
        }
        return false;
    }
};

//
// A clock the test drives rather than the wall clock (TypeScript: the FixedTimestampProvider of
// sync-verification.test.ts and the SettableTimestampProvider of sync-metadata-edit.test.ts).
//
pub const SettableTimestampProvider = struct {
    // The time every call reports, in milliseconds.
    current: i64,

    //
    // Moves the clock forward.
    //
    pub fn advance(self: *SettableTimestampProvider, milliseconds: i64) void {
        self.current += milliseconds;
    }

    //
    // Gets the ITimestampProvider interface for this clock.
    //
    pub fn timestampProvider(self: *SettableTimestampProvider) utils.timestamp_provider.ITimestampProvider {
        return .{ .ptr = self, .vtable = &vtable };
    }

    //
    // The ITimestampProvider functions of this clock.
    //
    const vtable: utils.timestamp_provider.ITimestampProvider.VTable = .{
        .now = now,
        .dateNow = dateNow,
    };

    //
    // The current time in milliseconds.
    //
    fn now(ptr: *anyopaque, io: std.Io) i64 {
        _ = io;
        const self: *SettableTimestampProvider = @ptrCast(@alignCast(ptr));
        return self.current;
    }

    //
    // The current time as a Date.
    //
    fn dateNow(ptr: *anyopaque, io: std.Io) utils.timestamp_provider.Date {
        _ = io;
        const self: *SettableTimestampProvider = @ptrCast(@alignCast(ptr));
        return .{ .epochMilliseconds = self.current };
    }
};

//
// A uuid generator for a test (TypeScript: `new TestUuidGenerator()`).
//
pub fn testUuidGenerator(allocator: std.mem.Allocator) !utils.uuid_generator.IUuidGenerator {
    const uuidGenerator = try allocator.create(node_utils.test_uuid_generator.TestUuidGenerator);
    uuidGenerator.* = try node_utils.test_uuid_generator.TestUuidGenerator.init(allocator);
    return uuidGenerator.uuidGenerator();
}
