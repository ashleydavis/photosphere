//
// Tests for how a push moves a file between two encrypted databases (port of
// src/test/lib/sync-verbatim-push.test.ts).
//
// The stored bytes go across as they are. The ciphertext one database holds is exactly the
// ciphertext the other would write, so decrypting it on the way out and encrypting it again on the
// way in changes nothing but the time it takes, and on a phone that time is the whole cost of
// pushing an original: AES-256-CBC there runs in the engine's own JavaScript at about a fifth of a
// megabyte a second in each direction. Measured on a Pixel 6, a three megabyte photo took thirty
// seconds to push and a ninety megabyte video a quarter of an hour, for bytes the network carries
// in a few seconds.
//

const std = @import("std");
const merkle_tree_zig = @import("merkle-tree-zig");
const storage_zig = @import("storage-zig");
const encryption = @import("encryption-zig");
const node_api = @import("node-api-zig");
const helpers = @import("test-helpers.zig");
const MemoryStorage = @import("memory-storage.zig").MemoryStorage;
const sync_helpers = @import("sync-test-helpers.zig");
const merkle_tree = merkle_tree_zig.merkle_tree;
const IStorage = storage_zig.storage.IStorage;
const EncryptedStorage = storage_zig.encrypted_storage.EncryptedStorage;
const pushFiles = node_api.sync.pushFiles;
const chooseHowToPushBytes = node_api.sync.chooseHowToPushBytes;

//
// The id of the test databases.
//
const dbId = "8d4e5f6a-9b0c-4d1e-af2b-3c4d5e6f7a8b";

//
// The file the tests push.
//
const fileName = "asset/one.jpg";

//
// A key pair and the key map that reads what it wrote, as one database's keys.
// (Zig: the key pairs are the TypeScript generated fixture keys of encryption-zig, where the TypeScript test makes a
// fresh pair each time.)
//
const IDatabaseKeys = struct {
    // The storage options: the public key files are encrypted with and the private keys they are decrypted with.
    options: encryption.encryption_types.IStorageOptions,

    // The public key as it is written to `.db/encryption.pub`.
    publicKeyPem: []const u8,
};

//
// Loads one of the fixture key pairs ("ts" or "ts2").
//
fn makeKeys(allocator: std.mem.Allocator, name: []const u8) !IDatabaseKeys {
    const cwd = std.Io.Dir.cwd();
    const io = std.testing.io;
    const privateKeyPem = try cwd.readFileAlloc(io, try std.fmt.allocPrint(allocator, "{s}/{s}-private.pem", .{ helpers.KEYS_DIR, name }), allocator, .unlimited);
    const publicKeyPem = try cwd.readFileAlloc(io, try std.fmt.allocPrint(allocator, "{s}/{s}-public.pem", .{ helpers.KEYS_DIR, name }), allocator, .unlimited);
    const loaded = try encryption.key_utils.loadEncryptionKeysFromPem(allocator, &.{.{
        .privateKeyPem = privateKeyPem,
        .publicKeyPem = publicKeyPem,
    }});
    return .{
        .options = loaded.options,
        .publicKeyPem = publicKeyPem,
    };
}

//
// An encrypted database over an in-memory store: the raw store, the storage that reads and writes
// through the encryption, and the key file that names its key.
//
const IEncryptedDatabase = struct {
    // What is stored: ciphertext.
    raw: *MemoryStorage,

    // What the database holds: plaintext, through the encryption.
    storage: *EncryptedStorage,
};

//
// The contents the tests give a file.
//
fn contentsOf(allocator: std.mem.Allocator, name: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, "the contents of {s}", .{name});
}

//
// Fills a storage with the given files and a merkle tree describing exactly them.
//
fn fillDatabase(allocator: std.mem.Allocator, io: std.Io, storage: IStorage, fileNames: []const []const u8) !void {
    const files = try allocator.alloc(sync_helpers.IFileToStore, fileNames.len);
    for (fileNames, 0..) |name, index| {
        files[index] = .{
            .name = name,
            .contents = try contentsOf(allocator, name),
        };
    }
    try sync_helpers.fillDatabase(allocator, io, storage, dbId, files, &.{});
}

//
// Makes an encrypted database under the given keys, holding the given files.
//
fn makeEncryptedDatabase(allocator: std.mem.Allocator, io: std.Io, keys: IDatabaseKeys, fileNames: []const []const u8) !IEncryptedDatabase {
    const raw = try allocator.create(MemoryStorage);
    raw.* = MemoryStorage.init(allocator);
    const storage = try allocator.create(EncryptedStorage);
    storage.* = EncryptedStorage.init("encrypted", raw.asStorage(), keys.options.decryptionKeyMap.?, keys.options.encryptionPublicKey.?);
    try raw.asStorage().write(allocator, io, ".db/encryption.pub", null, keys.publicKeyPem);
    try fillDatabase(allocator, io, storage.storage(), fileNames);
    return .{
        .raw = raw,
        .storage = storage,
    };
}

test "moves the stored bytes as they are" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    var capture: sync_helpers.Capture = undefined;
    capture.start(allocator);
    defer capture.stop();

    const keys = try makeKeys(allocator, "ts");
    const source = try makeEncryptedDatabase(allocator, io, keys, &.{fileName});
    const target = try makeEncryptedDatabase(allocator, io, keys, &.{});

    const bytes = try chooseHowToPushBytes(allocator, io, source.storage.storage(), source.raw.asStorage(), target.storage.storage(), target.raw.asStorage());
    try std.testing.expectEqual(true, bytes.verbatim);

    try pushFiles(allocator, io, source.storage.storage(), target.storage.storage(), try sync_helpers.makeBsonDatabase(allocator, target.storage.storage()), bytes);

    // Byte for byte the source's ciphertext, which it could only be if nothing was decrypted
    // and encrypted again on the way: a fresh encryption draws a fresh key and a fresh IV.
    try std.testing.expectEqualSlices(u8, (try source.raw.asStorage().read(allocator, io, fileName)).?, (try target.raw.asStorage().read(allocator, io, fileName)).?);

    // And the target reads it back as what the database holds.
    try std.testing.expectEqualStrings(try contentsOf(allocator, fileName), (try target.storage.storage().read(allocator, io, fileName)).?);
}

test "hands the store the hash of the stored bytes, so the store can check them" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    var capture: sync_helpers.Capture = undefined;
    capture.start(allocator);
    defer capture.stop();

    const keys = try makeKeys(allocator, "ts");
    const source = try makeEncryptedDatabase(allocator, io, keys, &.{fileName});
    const target = try makeEncryptedDatabase(allocator, io, keys, &.{});

    try pushFiles(allocator, io, source.storage.storage(), target.storage.storage(), try sync_helpers.makeBsonDatabase(allocator, target.storage.storage()), try chooseHowToPushBytes(allocator, io, source.storage.storage(), source.raw.asStorage(), target.storage.storage(), target.raw.asStorage()));

    const storedBytes = (try source.raw.asStorage().read(allocator, io, fileName)).?;
    try std.testing.expectEqualSlices(u8, try sync_helpers.hashOf(allocator, storedBytes), (try target.raw.asStorage().storedHash(allocator, io, fileName)).?);
}

test "records the file in the target's tree as the source's tree has it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    var capture: sync_helpers.Capture = undefined;
    capture.start(allocator);
    defer capture.stop();

    const keys = try makeKeys(allocator, "ts");
    const source = try makeEncryptedDatabase(allocator, io, keys, &.{fileName});
    const target = try makeEncryptedDatabase(allocator, io, keys, &.{});

    try pushFiles(allocator, io, source.storage.storage(), target.storage.storage(), try sync_helpers.makeBsonDatabase(allocator, target.storage.storage()), try chooseHowToPushBytes(allocator, io, source.storage.storage(), source.raw.asStorage(), target.storage.storage(), target.raw.asStorage()));

    const sourceTree = (try merkle_tree.loadTree(allocator, io, ".db/files.dat", source.storage.storage(), "FTRE")).?;
    const targetTree = (try merkle_tree.loadTree(allocator, io, ".db/files.dat", target.storage.storage(), "FTRE")).?;
    const sourceInfo = (try merkle_tree.getItemInfo(&sourceTree, fileName)).?;
    const targetInfo = (try merkle_tree.getItemInfo(&targetTree, fileName)).?;
    try std.testing.expectEqualSlices(u8, sourceInfo.hash, targetInfo.hash);
    try std.testing.expectEqual(sourceInfo.length, targetInfo.length);
    try std.testing.expectEqual(sourceInfo.lastModified, targetInfo.lastModified);
}

test "goes through the databases, decrypting and encrypting on the way" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    var capture: sync_helpers.Capture = undefined;
    capture.start(allocator);
    defer capture.stop();

    const source = try makeEncryptedDatabase(allocator, io, try makeKeys(allocator, "ts"), &.{fileName});
    const target = try makeEncryptedDatabase(allocator, io, try makeKeys(allocator, "ts2"), &.{});

    const bytes = try chooseHowToPushBytes(allocator, io, source.storage.storage(), source.raw.asStorage(), target.storage.storage(), target.raw.asStorage());
    try std.testing.expectEqual(false, bytes.verbatim);

    try pushFiles(allocator, io, source.storage.storage(), target.storage.storage(), try sync_helpers.makeBsonDatabase(allocator, target.storage.storage()), bytes);

    try std.testing.expect(!std.mem.eql(u8, (try source.raw.asStorage().read(allocator, io, fileName)).?, (try target.raw.asStorage().read(allocator, io, fileName)).?));
    try std.testing.expectEqualStrings(try contentsOf(allocator, fileName), (try target.storage.storage().read(allocator, io, fileName)).?);
}

test "is never verbatim when either side is not encrypted" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    var capture: sync_helpers.Capture = undefined;
    capture.start(allocator);
    defer capture.stop();

    const encrypted = try makeEncryptedDatabase(allocator, io, try makeKeys(allocator, "ts"), &.{fileName});
    var plain = MemoryStorage.init(allocator);
    try fillDatabase(allocator, io, plain.asStorage(), &.{});

    try std.testing.expectEqual(false, (try chooseHowToPushBytes(allocator, io, encrypted.storage.storage(), encrypted.raw.asStorage(), plain.asStorage(), plain.asStorage())).verbatim);
    try std.testing.expectEqual(false, (try chooseHowToPushBytes(allocator, io, plain.asStorage(), plain.asStorage(), encrypted.storage.storage(), encrypted.raw.asStorage())).verbatim);
}
