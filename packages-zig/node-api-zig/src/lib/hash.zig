const std = @import("std");
const merkle_tree_zig = @import("merkle-tree-zig");
const file_scanner = @import("file-scanner.zig");
const IFileStat = file_scanner.IFileStat;
const IHashedData = merkle_tree_zig.merkle_tree.IHashedData;
const Sha256 = std.crypto.hash.sha2.Sha256;
const utils = @import("utils-zig");
const api = @import("api-zig");
const hash_cache = @import("hash-cache.zig");
const validation = @import("validation.zig");
const errors = utils.errors;
const log = &utils.log.log;
const HashCache = hash_cache.HashCache;
const validateFile = validation.validateFile;
const IFileCacheIdentity = api.import_assets_types.IFileCacheIdentity;

//
// The size of the buffer used to feed the stream into the hash.
//
const HASH_BUFFER_SIZE = 64 * 1024;

//
// Computes a hash from a stream.
// (Zig: the stream is a *std.Io.Reader and the hash is returned by value; the caller destroys the stream.)
//
pub fn computeHash(inputStream: *std.Io.Reader) ![Sha256.digest_length]u8 {
    var buffer: [HASH_BUFFER_SIZE]u8 = undefined;
    var hashing = std.Io.Writer.Hashing(Sha256).init(&buffer);

    _ = try inputStream.streamRemaining(&hashing.writer);
    try hashing.writer.flush();

    return hashing.hasher.finalResult();
}

// Not ported: IPathBearingStream, IFileHashingCrypto (the native hasher is the mobile worker's crypto shim; in Bun
// `crypto` is Node's, which has no hashFileSync).

//
// Hashes a whole file natively and returns the digest (TypeScript: `(filePath: string) => Buffer`).
// (A Zig closure: `function` is called with `context`.)
//
pub const NativeFileHasher = struct {
    // The state of the hasher, passed to function.
    context: ?*anyopaque,

    // The hasher.
    function: *const fn (context: ?*anyopaque, allocator: std.mem.Allocator, filePath: []const u8) anyerror![]const u8,
};

//
// Whether hashing a whole file natively is available here, and the function when it is.
//
// Exported so the choice can be tested rather than inferred from which platform a test happens to
// run on.
// (Zig: the CLI's `crypto` is Node's as Bun provides it, which has no hashFileSync, so there is none.)
//
pub fn getNativeFileHasher() ?NativeFileHasher {
    return null;
}

//
// Computes the SHA-256 of a whole file: through the native hasher when one is handed in, and by
// streaming the file through a JS hash when it is not.
//
// The hasher is passed in rather than looked up in here so that both paths can be tested. Looking
// it up inside would leave the native path unreachable from a test on a desktop machine, and a path
// that has never run is a path nobody has checked.
//
// Both paths must produce identical digests. These are the identity of every asset and the key of
// the hash cache, so a digest that differed by a byte would make every database already written
// look wrong, and it would do it silently: photos would re-import and the cache would never hit.
//
pub fn computeFileHash(allocator: std.mem.Allocator, io: std.Io, filePath: []const u8, hashFileNatively: ?NativeFileHasher) ![]const u8 {
    if (hashFileNatively) |hasher| {
        return hasher.function(hasher.context, allocator, filePath);
    }

    const file = std.Io.Dir.cwd().openFile(io, filePath, .{}) catch |err| {
        if (err == error.FileNotFound) {
            return errors.throwError("ENOENT: no such file or directory, open '{s}'", .{filePath});
        }
        return err;
    };
    defer file.close(io);
    var readBuffer: [HASH_BUFFER_SIZE]u8 = undefined;
    var fileReader = file.reader(io, &readBuffer);
    const hash = try computeHash(&fileReader.interface);
    return allocator.dupe(u8, &hash);
}

//
// Computes the hash of an asset storage file (no caching since data is already in merkle tree).
// Takes a stream directly to avoid reading the file back from storage.
// (Zig: the hash is allocated with the allocator.)
//
pub fn computeAssetHash(allocator: std.mem.Allocator, stream: *std.Io.Reader, fileStat: IFileStat) !IHashedData {
    //
    // Hashed natively when the stream is reading a file and a native hasher is available, and by
    // streaming it through a JS hash otherwise.
    //
    // This is the same choice `computeFileHash` makes, and it is here for the same reason it is
    // there. Every asset written to storage is read back and hashed to put its hash in the merkle
    // tree, three times per photo for the original, the thumbnail and the display version. On a
    // phone that was the pure-JS SHA-256 over bytes fetched across the engine bridge as base64: it
    // was 54% of an import, and it was invisible until the unmeasured remainder was given a counter.
    //
    // Both paths produce the same digest, which is what makes choosing between them safe: these are
    // the hashes recorded in the merkle tree, and one that differed by a byte would make the tree
    // disagree with the files it describes.
    //
    // (Zig: getNativeFileHasher() is undefined outside the mobile worker, so this is always the
    // streaming path.)
    //
    const hash = try computeHash(stream);
    return .{
        .hash = try allocator.dupe(u8, &hash),
        .lastModified = fileStat.lastModified,
        .length = fileStat.length,
    };
}

//
// Gets a hash from the cache if it matches what the file is expected to be.
//
// With no identity the file is looked up under its own path and compared against its own stat,
// which is what every manual import does. With one, the item is looked up under the identity the
// caller supplied and compared against that instead: a photo library item is filed under its source
// id, and the temporary copy it was exported to has a path and a modified time that were both
// minted by the copy and match nothing. See IFileCacheIdentity.
//
pub fn getHashFromCache(allocator: std.mem.Allocator, filePath: []const u8, fileStat: IFileStat, hashCache: *HashCache, cacheIdentity: ?IFileCacheIdentity) !?IHashedData {
    const key = if (cacheIdentity) |identity| identity.key else filePath;
    const expectedLength = if (cacheIdentity) |identity| identity.length else fileStat.length;
    const expectedLastModified = if (cacheIdentity) |identity| identity.lastModified else fileStat.lastModified;

    const cacheEntry = try hashCache.getHash(allocator, key);
    if (cacheEntry) |entry| {
        if (entry.length == expectedLength and entry.lastModified == expectedLastModified) {
            return .{
                .hash = entry.hash,
                .lastModified = fileStat.lastModified,
                .length = fileStat.length,
            };
        }
    }
    return null;
}

//
// Validates and computes the hash of a file for import.
// Returns the hashed file data on success, or undefined on failure.
//
pub fn validateAndHash(
    allocator: std.mem.Allocator,
    io: std.Io,
    filePath: []const u8, // Actual file path (always a valid file, already extracted if from zip)
    fileStat: IFileStat,
    contentType: []const u8,
    logicalPath: []const u8, // Logical path for display (always set - equals filePath for non-zip files)
) !?IHashedData {
    // filePath is always a valid file (already extracted if from zip)
    // Validate the file
    const isValid = validateFile(allocator, io, filePath, contentType, fileStat) catch |err| {
        // Use logicalPath for display (always set)
        log.exception(try std.fmt.allocPrint(allocator, "File \"{s}\" has failed its validation with error: {s}", .{ logicalPath, errors.errorMessage(err) }), err);
        return null;
    };
    if (!isValid) {
        return null;
    }

    // Compute hash using the file (already extracted if from zip)
    const hash = try computeFileHash(allocator, io, filePath, getNativeFileHasher());
    return .{
        .hash = hash,
        .lastModified = fileStat.lastModified,
        .length = fileStat.length,
    };
}

