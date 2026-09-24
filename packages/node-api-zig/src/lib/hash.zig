const std = @import("std");
const merkle_tree_zig = @import("merkle-tree-zig");
const file_scanner = @import("file-scanner.zig");
const IFileStat = file_scanner.IFileStat;
const IHashedData = merkle_tree_zig.merkle_tree.IHashedData;
const Sha256 = std.crypto.hash.sha2.Sha256;

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

//
// Computes the hash of an asset storage file (no caching since data is already in merkle tree).
// Takes a stream directly to avoid reading the file back from storage.
// (Zig: the hash is allocated with the allocator.)
//
pub fn computeAssetHash(allocator: std.mem.Allocator, stream: *std.Io.Reader, fileStat: IFileStat) !IHashedData {
    //
    // Compute the hash of the file.
    //
    const hash = try computeHash(stream);
    return .{
        .hash = try allocator.dupe(u8, &hash),
        .lastModified = fileStat.lastModified,
        .length = fileStat.length,
    };
}

// Not ported: getHashFromCache, validateAndHash (psi add, not psi replicate or psi verify).

