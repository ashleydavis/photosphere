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

// Not ported: IPathBearingStream, IFileHashingCrypto, getNativeFileHasher, computeFileHash. The native
// hasher is the mobile worker's crypto shim; in Bun `crypto` is Node's, which has no hashFileSync, so
// getNativeFileHasher returns undefined and every hash is taken by streaming (see computeAssetHash).

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

// Not ported: getHashFromCache, validateAndHash (psi add, not psi replicate or psi verify).

