const std = @import("std");
const utils = @import("utils-zig");
const node_utils = @import("node-utils-zig");
const bdb = @import("bdb-zig");
const database_cache_dir = @import("database-cache-dir.zig");
const errors = utils.errors;
const log = &utils.log.log;
const path = node_utils.path;
const pathExists = node_utils.fs.pathExists;
const updateFileRawOptimistic = node_utils.fs.updateFileRawOptimistic;
const localeCompare = bdb.locale_compare.localeCompare;
const getDatabaseCacheDir = database_cache_dir.getDatabaseCacheDir;
const Sha256 = std.crypto.hash.sha2.Sha256;

//
// File structure:
//  - Version: 4 bytes (uint32)
//  - Entry count: 4 bytes (uint32)
//  - Entries: variable length
//  - Checksum: 32 bytes (SHA-256) at the end
//
// Hash cache entry structure:
// - Key length: 4 bytes (uint32)
// - Key: variable length
// - Hash: 32 bytes (SHA-256)
// - File size: 6 bytes (uint48)
// - Last modified: 6 bytes (uint48)
// - Asset id: 36 bytes (ASCII, zero-padded, all zero when there is none)
// - Keyed by source id: 1 byte (0 or 1)
//

//
// The version of the file format. Bump it whenever the entry layout changes, and write no
// migration and no reader for the older layout.
//
// The whole cache is throwaway: everything in it can be recomputed from the files themselves, and
// the user can delete the lot with `psi hash-cache clear` without losing anything. So a cache file
// of any version but this one is discarded and rebuilt, which decodeEntries does by returning
// undefined on a version that is not equal to this one. Not "older than", not "unsupported": not
// equal.
//
const HASH_CACHE_VERSION = 2;

//
// How many bytes an asset id occupies in an entry.
//
// Fixed width, because an asset id is a UUID and a UUID is always 36 characters. Keeping it fixed
// is what lets an entry's size still be worked out from its key length alone, which every offset
// walk in this file relies on. An entry with no asset id yet stores 36 zero bytes.
//
const ASSET_ID_BYTES = 36;

//
// How many times a save retries when another process publishes a new cache file underneath it.
// Each retry re-reads the winner's file and re-applies this instance's changes onto it. This is
// set high because the cache is genuinely contended: every worker in every running instance saves
// after each file it hashes, so a writer can lose several times in a row before it lands. Losing
// all of them means the save throws and its entries wait until the next save.
//
const SAVE_RETRIES = 20;

//
// Allocates what a HashCache keeps: its buffer, lookup table and changeset, which are replaced and freed as the
// cache changes, so they cannot live in an arena. (No TypeScript counterpart: garbage collection.)
//
const cache_allocator = std.heap.smp_allocator;

//
// Recognises the two ways updateFileRawOptimistic reports that it could not get in, as opposed to
// something being wrong.
//
// It gives up either because it never won the lock or because another writer kept changing the file
// under it, and it says so in the message of a plain Error. Both are ordinary outcomes for a file
// as contended as the hash cache, and both mean "try again later", so the save swallows them. Every
// other error means the save itself is broken and must not be mistaken for a busy moment.
//
// Matching on the message is the only discriminator available, because both are plain Errors. That
// is not fragile in the direction that matters: if those messages ever change, a contended save
// starts throwing where it used to be quiet, which is noticed immediately, rather than a fault
// going quiet again.
//
fn isUpdateContentionError(err: anyerror) bool {
    const message = if (err == error.Thrown) errors.lastErrorMessage() else "";
    return std.mem.indexOf(u8, message, "could not take the update lock") != null or std.mem.indexOf(u8, message, "kept changing under concurrent writers") != null;
}

//
// The directory holding the hash cache of one database.
//
// There is one cache per database, not one per machine, because an entry records the id the file has
// in the database. A photo imported into two databases has two ids and one entry cannot hold both,
// so the caches are kept apart rather than making the entry carry a map of database to id, which
// would mean a variable-length field in a fixed-width binary format for the sake of a case that is
// rare.
//
// It sits in this machine's cache directory for that database, which outlives a restart on the
// desktop, the CLI and a phone alike while still telling the operating system, the backup tool and
// the disk cleaner that everything in it can be thrown away. See getDatabaseCacheDir and getCacheDir.
//
// It used to sit under the process temp directory, and that was wrong everywhere rather than only on
// one platform: Linux clears /tmp at boot and sweeps old files out of it, macOS reaps /var/folders
// after a few days of not being touched, and a phone's "temp" is a directory the app itself is free
// to clear. Everything the cache exists to avoid, which for a photo library is a full copy and a full
// hash of every photo already imported, was being paid again after whichever of those happened first,
// and nothing announced it.
//
pub fn getHashCacheDir(allocator: std.mem.Allocator, databasePath: []const u8) ![]const u8 {
    return path.join(allocator, &.{ try getDatabaseCacheDir(allocator, databasePath), "hash-cache" });
}

//
// A single decoded entry of the hash cache.
//
pub const IHashCacheEntry = struct {
    // What this entry is filed under: the normalized path of a file, or the stable source id of an
    // item in a device photo library. A library item has no path until it has been copied out of
    // the library, which is the copy this cache exists to avoid, so its source id is the only
    // identity available at the moment the question is asked.
    key: []const u8,

    // SHA-256 hash of the file's content (always 32 bytes).
    hash: [32]u8,

    // Length of the file in bytes.
    length: u64,

    // Last modified time of the file, in milliseconds since the epoch. For a source-keyed entry
    // this is the item's created time as the library reports it, because the temporary copy's own
    // modified time is minted by the copy and matches nothing.
    lastModified: i64,

    // The id this file was given in the database this cache belongs to, once it is known to be in
    // there. Undefined means it has been hashed but is not known to be in the database, which is
    // answered by looking the hash up in the database itself.
    assetId: ?[]const u8,

    // True when the key is a source id rather than a file path. Recorded so the sweep that drops
    // entries for photos that have left the device can tell the two apart: a file path that is not
    // in the photo library is not a dead entry, it is a manual import.
    keyedBySourceId: bool,
};

//
// What the cache knows about one file.
//
pub const ICachedHash = struct {
    // SHA-256 hash of the file's content.
    hash: []const u8,

    // Length of the file in bytes.
    length: u64,

    // Last modified time recorded against the entry (milliseconds since the epoch, like a JS Date).
    lastModified: i64,

    // The id this file has in the database, or undefined when it is not known to be in there.
    assetId: ?[]const u8,
};

//
// One entry as it is listed for a reader, with the hash already in hex.
//
pub const IHashCacheListing = struct {
    // What the entry is filed under: a file path, or the source id of a photo library item.
    key: []const u8,

    // SHA-256 hash of the file's content, lower-case hex.
    hash: []const u8,

    // Length of the file in bytes.
    size: u64,

    // Last modified time recorded against the entry (milliseconds since the epoch, like a JS Date).
    lastModified: i64,

    // The id this file has in the database, or undefined when it is not known to be in there.
    assetId: ?[]const u8,

    // True when the key is a source id rather than a file path.
    keyedBySourceId: bool,
};

//
// The hash of one file, ready to be recorded in the cache.
//
pub const IHashToCache = struct {
    // SHA-256 hash of the file's content (must be 32 bytes).
    hash: []const u8,

    // Length of the file in bytes.
    length: u64,

    // The modified time to record against the entry (milliseconds since the epoch, like a JS Date).
    lastModified: i64,
};

//
// Node's `buf.readUInt32LE(offset)`. (No TypeScript counterpart.)
//
fn readUInt32LE(buffer: []const u8, offset: usize) u32 {
    return std.mem.readInt(u32, buffer[offset..][0..4], .little);
}

//
// Node's `buf.writeUInt32LE(value, offset)`. (No TypeScript counterpart.)
//
fn writeUInt32LE(buffer: []u8, value: u32, offset: usize) void {
    std.mem.writeInt(u32, buffer[offset..][0..4], value, .little);
}

//
// Node's `buf.readUIntLE(offset, 6)`. (No TypeScript counterpart.)
//
fn readUInt48LE(buffer: []const u8, offset: usize) u64 {
    return std.mem.readInt(u48, buffer[offset..][0..6], .little);
}

//
// Node's `buf.writeUIntLE(value, offset, 6)`, which throws a RangeError for a value that does not fit 48 bits.
// (No TypeScript counterpart.)
//
fn writeUInt48LE(buffer: []u8, value: i128, offset: usize) !void {
    if (value < 0 or value >= (1 << 48)) {
        return errors.throwError("The value of \"value\" is out of range. It must be >= 0 and < 2 ** 48. Received {d}", .{value});
    }
    std.mem.writeInt(u48, buffer[offset..][0..6], @intCast(value), .little);
}

//
// A sorted list of entries, with the arena their keys and asset ids live in. (No TypeScript counterpart: TypeScript
// returns the array.)
//
const IDecodedEntries = struct {
    // Owns the keys and asset ids.
    arena: std.heap.ArenaAllocator,

    // The entries.
    entries: []IHashCacheEntry,
};

//
// A record of the loaded buffer of the hash cache.
//
pub const HashCache = struct {
    // The file layout without its trailing checksum, with spare room at the end for new entries.
    buffer: ?[]u8 = null,

    // Whether load has run.
    initialized: bool = false,

    // Whether there are changes that have not been saved.
    isDirty: bool = false,

    // The number of entries in the buffer.
    entryCount: u32 = 0,

    // The offset of each entry in the buffer, in order.
    offsetLookup: std.ArrayList(usize) = .empty,

    //
    // Entries this instance has added or updated since the last load or save, keyed by normalized
    // file path. They are merged onto the on-disk cache at save time so a concurrent writer's
    // entries are kept instead of being overwritten by this instance's whole snapshot.
    // (Keys and asset ids are owned by cache_allocator; iterated in insertion order like a JS Map.)
    //
    pendingUpserts: std.StringArrayHashMapUnmanaged(IHashCacheEntry) = .empty,

    //
    // Normalized file paths this instance has removed since the last load or save. Applied to the
    // on-disk cache at save time, before the pending upserts.
    // (Keys are owned by cache_allocator.)
    //
    pendingRemovals: std.StringArrayHashMapUnmanaged(void) = .empty,

    // The directory where the hash cache will be stored.
    cacheDir: []const u8,

    // Whether the cache should skip saves when in readonly mode.
    isReadonly: bool,

    //
    // Creates a new hash cache (TypeScript: the constructor).
    // The directory is copied. Free the cache with deinit.
    //
    pub fn init(cacheDir: []const u8, isReadonly: bool) !HashCache {
        return .{
            .cacheDir = try cache_allocator.dupe(u8, cacheDir),
            .isReadonly = isReadonly,
        };
    }

    //
    // Frees the cache. (No TypeScript counterpart: garbage collection.)
    //
    pub fn deinit(self: *HashCache) void {
        if (self.buffer) |buffer| {
            cache_allocator.free(buffer);
        }
        self.buffer = null;
        self.offsetLookup.deinit(cache_allocator);
        self.clearPendingUpserts();
        self.pendingUpserts.deinit(cache_allocator);
        self.clearPendingRemovals();
        self.pendingRemovals.deinit(cache_allocator);
        cache_allocator.free(self.cacheDir);
    }

    //
    // Frees the changeset's upserts. (No TypeScript counterpart: `pendingUpserts.clear()`.)
    //
    fn clearPendingUpserts(self: *HashCache) void {
        for (self.pendingUpserts.keys(), self.pendingUpserts.values()) |key, entry| {
            cache_allocator.free(key);
            if (entry.assetId) |assetId| {
                cache_allocator.free(assetId);
            }
        }
        self.pendingUpserts.clearRetainingCapacity();
    }

    //
    // Frees the changeset's removals. (No TypeScript counterpart: `pendingRemovals.clear()`.)
    //
    fn clearPendingRemovals(self: *HashCache) void {
        for (self.pendingRemovals.keys()) |key| {
            cache_allocator.free(key);
        }
        self.pendingRemovals.clearRetainingCapacity();
    }

    //
    // Puts an entry in the changeset's upserts (`pendingUpserts.set(key, entry)`), copying its key and asset id.
    // (No TypeScript counterpart.)
    //
    fn setPendingUpsert(self: *HashCache, key: []const u8, entry: IHashCacheEntry) !void {
        const ownedAssetId = if (entry.assetId) |assetId| try cache_allocator.dupe(u8, assetId) else null;
        errdefer if (ownedAssetId) |assetId| cache_allocator.free(assetId);
        if (self.pendingUpserts.getEntry(key)) |existing| {
            if (existing.value_ptr.assetId) |previousAssetId| {
                cache_allocator.free(previousAssetId);
            }
            existing.value_ptr.* = entry;
            existing.value_ptr.key = existing.key_ptr.*;
            existing.value_ptr.assetId = ownedAssetId;
            return;
        }
        const ownedKey = try cache_allocator.dupe(u8, key);
        errdefer cache_allocator.free(ownedKey);
        var ownedEntry = entry;
        ownedEntry.key = ownedKey;
        ownedEntry.assetId = ownedAssetId;
        try self.pendingUpserts.put(cache_allocator, ownedKey, ownedEntry);
    }

    //
    // Removes a key from the changeset's upserts (`pendingUpserts.delete(key)`). (No TypeScript counterpart.)
    //
    fn deletePendingUpsert(self: *HashCache, key: []const u8) void {
        if (self.pendingUpserts.fetchOrderedRemove(key)) |removed| {
            cache_allocator.free(removed.key);
            if (removed.value.assetId) |assetId| {
                cache_allocator.free(assetId);
            }
        }
    }

    //
    // Removes a key from the changeset's removals (`pendingRemovals.delete(key)`). (No TypeScript counterpart.)
    //
    fn deletePendingRemoval(self: *HashCache, key: []const u8) void {
        if (self.pendingRemovals.fetchOrderedRemove(key)) |removed| {
            cache_allocator.free(removed.key);
        }
    }

    //
    // Adds a key to the changeset's removals (`pendingRemovals.add(key)`). (No TypeScript counterpart.)
    //
    fn addPendingRemoval(self: *HashCache, key: []const u8) !void {
        if (self.pendingRemovals.contains(key)) {
            return;
        }
        const ownedKey = try cache_allocator.dupe(u8, key);
        errdefer cache_allocator.free(ownedKey);
        try self.pendingRemovals.put(cache_allocator, ownedKey, {});
    }

    //
    // The form a key is stored and looked up under.
    //
    // A leading slash goes, and a backslash becomes a forward slash, so the same file named either
    // way is one entry rather than two.
    //
    // One function rather than the same two lines written out at each entry point, because written
    // out they drifted: getHash and removeHash dropped the leading slash and left backslashes alone,
    // while upsertHash and setAssetId did both. On Windows that meant a file written under
    // "C:\photos\one.jpg" was stored as "C:/photos/one.jpg" and never found again, so the cache
    // answered nothing and every import hashed every file it had already hashed.
    //
    fn normalizeKey(allocator: std.mem.Allocator, key: []const u8) ![]u8 {
        const withoutLeadingSlash = if (std.mem.startsWith(u8, key, "/")) key[1..] else key;
        const normalized = try allocator.dupe(u8, withoutLeadingSlash);
        std.mem.replaceScalar(u8, normalized, '\\', '/');
        return normalized;
    }

    //
    // Gets the size of a hash cache entry.
    //
    fn entrySize(keyLength: usize) usize {
        return 4 + keyLength + 32 + 6 + 6 + ASSET_ID_BYTES + 1; // keyLength + key + hash + size + lastModified + assetId + keyedBySourceId.
    }

    //
    // Reads an asset id out of an entry. All zero bytes means the entry has no asset id.
    //
    fn readAssetId(source: []const u8, offset: usize) ?[]const u8 {
        if (source[offset] == 0) {
            return null;
        }
        return std.mem.trimEnd(u8, source[offset .. offset + ASSET_ID_BYTES], "\x00");
    }

    //
    // Writes an asset id into an entry, zero-padded to the fixed width. Writing undefined clears it.
    //
    fn writeAssetId(target: []u8, offset: usize, assetId: ?[]const u8) !void {
        @memset(target[offset .. offset + ASSET_ID_BYTES], 0);
        const assetIdBytes = assetId orelse {
            return;
        };

        if (assetIdBytes.len > ASSET_ID_BYTES) {
            return errors.throwError("Asset id \"{s}\" is {d} bytes, which does not fit the {d} bytes the hash cache reserves for it.", .{ assetIdBytes, assetIdBytes.len, ASSET_ID_BYTES });
        }

        @memcpy(target[offset .. offset + assetIdBytes.len], assetIdBytes);
    }

    //
    // Computes SHA-256 checksum for corruption detection
    //
    fn computeChecksum(data: []const u8) [32]u8 {
        var checksum: [32]u8 = undefined;
        Sha256.hash(data, &checksum, .{});
        return checksum;
    }

    //
    // Decodes the bytes of a hash cache file into its entries.
    // Returns undefined when the bytes are not a usable cache file: absent, too small to hold a
    // header and checksum, of an unsupported version, failing their checksum, or describing an
    // entry that runs past the end of the data. Callers treat that as "start fresh" and do the
    // logging, so this stays free of side effects and of any dependency on instance state.
    // (Zig: the keys and asset ids are copied into the allocator.)
    //
    pub fn decodeEntries(allocator: std.mem.Allocator, fileBytes: ?[]const u8) !?[]IHashCacheEntry {
        const bytes = fileBytes orelse {
            return null;
        };
        if (bytes.len < 40) {
            return null;
        }

        const storedChecksum = bytes[bytes.len - 32 ..];
        const dataWithoutChecksum = bytes[0 .. bytes.len - 32];
        if (!std.mem.eql(u8, &computeChecksum(dataWithoutChecksum), storedChecksum)) {
            return null;
        }

        if (readUInt32LE(dataWithoutChecksum, 0) != HASH_CACHE_VERSION) {
            return null;
        }

        const entryCount = readUInt32LE(dataWithoutChecksum, 4);
        var entries: std.ArrayList(IHashCacheEntry) = .empty;
        var offset: usize = 8; // Start after the version and entry count headers.

        var entryIndex: u32 = 0;
        while (entryIndex < entryCount) : (entryIndex += 1) {
            if (offset + 4 > dataWithoutChecksum.len) {
                return null;
            }

            const keyLength = readUInt32LE(dataWithoutChecksum, offset);
            if (offset + entrySize(keyLength) > dataWithoutChecksum.len) {
                return null;
            }

            offset += 4; // Skip key length.
            const key = try allocator.dupe(u8, dataWithoutChecksum[offset .. offset + keyLength]);
            offset += keyLength; // Skip key.
            const hash = dataWithoutChecksum[offset..][0..32].*;
            offset += 32; // Skip hash.
            const length = readUInt48LE(dataWithoutChecksum, offset);
            offset += 6; // Skip size.
            const lastModified: i64 = @intCast(readUInt48LE(dataWithoutChecksum, offset));
            offset += 6; // Skip last modified.
            const assetId = if (readAssetId(dataWithoutChecksum, offset)) |id| try allocator.dupe(u8, id) else null;
            offset += ASSET_ID_BYTES; // Skip asset id.
            const keyedBySourceId = dataWithoutChecksum[offset] == 1;
            offset += 1; // Skip the source id flag.

            try entries.append(allocator, .{
                .key = key,
                .hash = hash,
                .length = length,
                .lastModified = lastModified,
                .assetId = assetId,
                .keyedBySourceId = keyedBySourceId,
            });
        }

        return entries.items;
    }

    //
    // Encodes entries into the bytes of a hash cache file: version and entry count headers, the
    // entries themselves, then a SHA-256 checksum of everything before it. The entries are written
    // in the order given, so callers must sort them the way the binary search expects.
    //
    pub fn encodeEntries(allocator: std.mem.Allocator, entries: []const IHashCacheEntry) ![]u8 {
        var totalEntryBytes: usize = 0;
        for (entries) |entry| {
            totalEntryBytes += entrySize(entry.key.len);
        }

        const dataBuffer = try allocator.alloc(u8, 8 + totalEntryBytes + 32);
        errdefer allocator.free(dataBuffer);
        @memset(dataBuffer, 0);
        writeUInt32LE(dataBuffer, HASH_CACHE_VERSION, 0);
        writeUInt32LE(dataBuffer, @intCast(entries.len), 4);

        var offset: usize = 8; // Start after the version and entry count headers.

        for (entries) |entry| {
            writeUInt32LE(dataBuffer, @intCast(entry.key.len), offset);
            offset += 4; // Skip key length.
            @memcpy(dataBuffer[offset .. offset + entry.key.len], entry.key);
            offset += entry.key.len; // Skip key.
            @memcpy(dataBuffer[offset .. offset + 32], &entry.hash);
            offset += 32; // Skip hash.
            try writeUInt48LE(dataBuffer, entry.length, offset);
            offset += 6; // Skip size.
            try writeUInt48LE(dataBuffer, entry.lastModified, offset);
            offset += 6; // Skip last modified.
            try writeAssetId(dataBuffer, offset, entry.assetId);
            offset += ASSET_ID_BYTES; // Skip asset id.
            dataBuffer[offset] = if (entry.keyedBySourceId) 1 else 0;
            offset += 1; // Skip the source id flag.
        }

        const checksum = computeChecksum(dataBuffer[0..offset]);
        @memcpy(dataBuffer[offset .. offset + 32], &checksum);
        return dataBuffer;
    }

    //
    // Loads the hash cache from storage.
    // This function is 100% safe - it will never throw exceptions.
    // If there's any problem loading the cache, it logs the error and starts fresh.
    // (Zig: running out of memory still fails.)
    //
    pub fn load(self: *HashCache, io: std.Io) !bool {
        var arena = std.heap.ArenaAllocator.init(cache_allocator);
        defer arena.deinit();
        const allocator = arena.allocator();
        const cachePath = try path.join(allocator, &.{ self.cacheDir, "hash-cache-x.dat" });

        return self.loadFrom(allocator, io, cachePath) catch |err| {
            if (err == error.OutOfMemory) {
                return err;
            }
            log.exception("Failed to load hash cache", err);
            try self.initializeFreshCache();
            return false;
        };
    }

    //
    // The body of load's try block. (No TypeScript counterpart: Zig needs it as a function to catch its errors.)
    //
    fn loadFrom(self: *HashCache, allocator: std.mem.Allocator, io: std.Io, cachePath: []const u8) !bool {
        // Check if file exists first
        if (!pathExists(io, cachePath)) {
            // File doesn't exist - create new cache
            try self.initializeFreshCache();
            return false;
        }

        // File exists - read and decode it.
        const fileBytes = try std.Io.Dir.cwd().readFileAlloc(io, cachePath, allocator, .unlimited);
        const entries = try decodeEntries(allocator, fileBytes) orelse {
            log.@"error"(try std.fmt.allocPrint(allocator, "Hash cache at {s} is unusable (too small, an unsupported version, corrupted, or failing its checksum) - starting with a fresh cache", .{cachePath}));
            try self.initializeFreshCache();
            return false;
        };

        try self.adoptEntries(entries);
        self.initialized = true;
        return true;
    }

    //
    // Initializes a fresh, empty cache
    //
    fn initializeFreshCache(self: *HashCache) !void {
        if (self.buffer) |buffer| {
            cache_allocator.free(buffer);
        }
        self.buffer = null;
        const freshBuffer = try cache_allocator.alloc(u8, 1024); // Start with 1KB
        @memset(freshBuffer, 0);
        self.buffer = freshBuffer;
        self.entryCount = 0;
        self.offsetLookup.clearRetainingCapacity();
        self.initialized = true;
        self.isDirty = false;
        self.clearPendingUpserts();
        self.clearPendingRemovals();
    }

    //
    // Adopts a sorted list of entries as this instance's state: it rebuilds the in-memory buffer
    // and lookup table from them and drops the changeset, because those entries are now exactly
    // what is on disk. The in-memory buffer holds the file layout without its trailing checksum,
    // which is what encodeEntries produces minus its last 32 bytes.
    //
    fn adoptEntries(self: *HashCache, entries: []const IHashCacheEntry) !void {
        const encoded = try encodeEntries(cache_allocator, entries);
        const shrunk = cache_allocator.realloc(encoded, encoded.len - 32) catch encoded[0 .. encoded.len - 32];
        if (self.buffer) |buffer| {
            cache_allocator.free(buffer);
        }
        self.buffer = shrunk;
        try self.createLookupTable();
        self.clearPendingUpserts();
        self.clearPendingRemovals();
        self.isDirty = false;
    }

    //
    // Create the lookup table of index to offset.
    // This function is safe - it will reset the cache if corruption is detected.
    //
    fn createLookupTable(self: *HashCache) !void {
        const buffer = self.buffer orelse {
            self.entryCount = 0;
            self.offsetLookup.clearRetainingCapacity();
            return;
        };
        if (buffer.len < 8) {
            self.entryCount = 0;
            self.offsetLookup.clearRetainingCapacity();
            return;
        }

        // Read entry count from bytes 4-7 (after version header)
        self.entryCount = readUInt32LE(buffer, 4);
        self.offsetLookup.clearRetainingCapacity();

        var offset: usize = 8; // Start after version and entry count headers

        var index: u32 = 0;
        while (index < self.entryCount) : (index += 1) {
            if (offset + 4 > buffer.len) {
                log.@"error"("Hash cache may be corrupted: insufficient data for entry");
                try self.initializeFreshCache();
                return;
            }

            // Read path length
            const keyLength = readUInt32LE(buffer, offset);
            const size = entrySize(keyLength);

            if (offset + size > buffer.len) {
                log.@"error"("Hash cache may be corrupted: entry extends beyond buffer");
                try self.initializeFreshCache();
                return;
            }

            // Store the offset in our lookup table
            try self.offsetLookup.append(cache_allocator, offset);

            // Skip to the next entry
            offset += size;
        }
    }

    //
    // Ensures the buffer has enough capacity for a new entry
    //
    fn ensureCapacity(self: *HashCache, requiredBytes: usize) !void {
        const buffer = self.buffer orelse {
            const newBuffer = try cache_allocator.alloc(u8, @max(1024, requiredBytes * 2));
            @memset(newBuffer, 0);
            self.buffer = newBuffer;
            return;
        };

        // Check current usage (entries start at offset 8 after version and entry count headers)
        var offset: usize = 8;

        var index: u32 = 0;
        while (index < self.entryCount) : (index += 1) {
            const keyLength = readUInt32LE(buffer, offset);
            offset += entrySize(keyLength);
        }

        const usedBytes = offset;

        // If we don't have enough space, resize the buffer
        if (usedBytes + requiredBytes > buffer.len) {
            const newSize = @max(buffer.len * 2, usedBytes + requiredBytes);
            const newBuffer = try cache_allocator.alloc(u8, newSize);
            @memset(newBuffer, 0);
            @memcpy(newBuffer[0..usedBytes], buffer[0..usedBytes]);
            cache_allocator.free(buffer);
            self.buffer = newBuffer;
        }
    }

    //
    // The mutator save hands to updateFileRawOptimistic (TypeScript: the arrow function), which merges this
    // instance's changes onto whatever is on disk.
    //
    const SaveMutator = struct {
        // The cache being saved.
        cache: *HashCache,

        // The merged entries of the last run, which save adopts.
        mergedEntries: []IHashCacheEntry = &.{},

        //
        // Merges the changeset onto the current bytes and encodes the result.
        //
        pub fn run(self: *SaveMutator, allocator: std.mem.Allocator, currentBytes: ?[]const u8) ![]const u8 {
            var entriesByKey: std.StringArrayHashMapUnmanaged(IHashCacheEntry) = .empty;

            for (try decodeEntries(allocator, currentBytes) orelse &.{}) |entry| {
                try entriesByKey.put(allocator, entry.key, entry);
            }

            for (self.cache.pendingRemovals.keys()) |removedKey| {
                _ = entriesByKey.orderedRemove(removedKey);
            }

            // This instance wins on a conflict: a freshly computed hash for a path is as valid
            // as the one already on disk.
            for (self.cache.pendingUpserts.keys(), self.cache.pendingUpserts.values()) |upsertedKey, entry| {
                try entriesByKey.put(allocator, upsertedKey, entry);
            }

            // Sorted with the same ordering the binary search in findEntryOffset relies on.
            const mergedEntries = try allocator.dupe(IHashCacheEntry, entriesByKey.values());
            std.mem.sort(IHashCacheEntry, mergedEntries, {}, entryLessThan);
            self.mergedEntries = mergedEntries;

            return encodeEntries(allocator, mergedEntries);
        }
    };

    //
    // Sort predicate: `first.key.localeCompare(second.key)`. (No TypeScript counterpart.)
    //
    fn entryLessThan(context: void, first: IHashCacheEntry, second: IHashCacheEntry) bool {
        _ = context;
        return localeCompare(first.key, second.key) < 0;
    }

    //
    // Saves the hash cache to storage.
    //
    // The save merges this instance's changes onto whatever is currently on disk rather than
    // writing its own snapshot over the top. Several Photosphere instances can share one cache
    // directory, and each one only knows about the entries it loaded plus the ones it added, so
    // overwriting would silently drop every entry another instance added in the meantime.
    // updateFileRawOptimistic does the read-modify-write under an exclusive lock, so overlapping
    // saves neither interleave their bytes nor lose each other's work. Under a load heavy enough
    // that it cannot get in at all, it gives up rather than failing the caller: the cache is only
    // an optimization, and a missing entry costs one recomputed hash.
    //
    pub fn save(self: *HashCache, io: std.Io) !void {
        if (!self.initialized or !self.isDirty or self.buffer == null or self.isReadonly) {
            return;
        }

        var arena = std.heap.ArenaAllocator.init(cache_allocator);
        defer arena.deinit();
        const allocator = arena.allocator();
        const cachePath = try path.join(allocator, &.{ self.cacheDir, "hash-cache-x.dat" });
        var mutator: SaveMutator = .{ .cache = self };

        updateFileRawOptimistic(allocator, io, cachePath, &mutator, SAVE_RETRIES) catch |err| {
            if (!isUpdateContentionError(err)) {
                // Not contention, so it is a real fault and it goes up.
                //
                // What this fixes: a fault here used to be indistinguishable from contention, so a
                // broken save looked exactly like a busy one and reported nothing.
                //
                // Why it was needed: on mobile the fs shim had no `open`, so taking the update lock
                // threw a TypeError on every single save. This catch used to take everything and
                // return, so the cache directory sat permanently empty, and every automatic import
                // re-hashed every photo it had already imported, for ever, with nothing to find.
                //
                // How it targets the problem: contention keeps the quiet path it has always had,
                // and everything else surfaces, so the next missing shim function fails loudly and
                // names itself instead of costing an hour a run in silence.
                return err;
            }

            // Too much contention to get in. Nothing is said about it, because nothing is wrong:
            // the changeset stays pending and stays dirty, so the next save carries these entries
            // along with whatever is added by then, and even if the process exits first the only
            // cost is recomputing those hashes next time.
            return;
        };

        // Adopt the merged result so this instance can serve entries other instances contributed.
        try self.adoptEntries(mutator.mergedEntries);
    }

    //
    // Gets the key of the entry at an offset. (No TypeScript counterpart: `buffer.toString('utf8', ...)` inline.)
    //
    fn keyAt(buffer: []const u8, entryOffset: usize) []const u8 {
        const keyLength = readUInt32LE(buffer, entryOffset);
        return buffer[entryOffset + 4 .. entryOffset + 4 + keyLength];
    }

    //
    // Gets the entry offset for a specific file path using binary search
    //
    // Returns the offset of the entry, or -(insertion point + 1) if not found
    //
    fn findEntryOffset(self: *HashCache, allocator: std.mem.Allocator, searchKey: []const u8) !i64 {
        const buffer = self.buffer orelse {
            return -1;
        };
        if (self.entryCount == 0) {
            return -1;
        }

        // Normalize the file path for consistent comparison
        const key = try allocator.dupe(u8, searchKey);
        std.mem.replaceScalar(u8, key, '\\', '/');

        // Binary search through the sorted entries
        var low: i64 = 0;
        var high: i64 = @as(i64, self.entryCount) - 1;

        while (low <= high) {
            const mid = @divFloor(low + high, 2);
            const entryOffset = try self.getEntryOffsetByIndex(mid);
            if (entryOffset < 0) {
                return -1; // Something went wrong
            }

            const entryKey = keyAt(buffer, @intCast(entryOffset));

            const comparison = localeCompare(key, entryKey);

            if (comparison == 0) {
                return entryOffset; // Found
            }
            else if (comparison < 0) {
                high = mid - 1; // Search in the lower half
            }
            else {
                low = mid + 1; // Search in the upper half
            }
        }

        return -(low + 1); // Return insertion point as a negative number
    }

    //
    // Gets the offset of an entry by its index
    //
    // Returns the offset of the entry, or -1 if out of bounds
    //
    fn getEntryOffsetByIndex(self: *HashCache, index: i64) !i64 {
        if (self.buffer == null or index < 0 or index >= self.entryCount) {
            return -1;
        }

        // The lookup table should always be fully populated
        if (index >= self.offsetLookup.items.len) {
            return errors.throwError("Index {d} is out of bounds for offset lookup table of length {d}", .{ index, self.offsetLookup.items.len });
        }

        return @intCast(self.offsetLookup.items[@intCast(index)]);
    }

    //
    // Retrieves a hash from the cache
    //
    // Returns what the cache knows about the file path, or the source id of a photo library item, or undefined
    // when it holds nothing under that key. (Zig: the hash and asset id are copied into the allocator.)
    //
    pub fn getHash(self: *HashCache, allocator: std.mem.Allocator, key: []const u8) !?ICachedHash {
        if (!self.initialized) {
            return null;
        }
        const buffer = self.buffer orelse {
            return null;
        };

        const entryOffset = try self.findEntryOffset(allocator, try normalizeKey(allocator, key));

        if (entryOffset < 0) {
            return null; // Not found
        }

        var offset: usize = @intCast(entryOffset);
        const keyLength = readUInt32LE(buffer, offset);
        offset += 4 + keyLength; // Skip key.
        const hash = try allocator.dupe(u8, buffer[offset .. offset + 32]);
        offset += 32; // Skip hash.
        const length = readUInt48LE(buffer, offset);
        offset += 6; // Skip size.
        const lastModified: i64 = @intCast(readUInt48LE(buffer, offset));
        offset += 6; // Skip last modified.
        const assetId = if (readAssetId(buffer, offset)) |id| try allocator.dupe(u8, id) else null;

        return .{
            .hash = hash,
            .length = length,
            .lastModified = lastModified,
            .assetId = assetId,
        };
    }

    //
    // Adds or updates the hash of a file, filed under its path.
    //
    pub fn addHash(self: *HashCache, key: []const u8, hashedFile: IHashToCache) !void {
        try self.upsertHash(key, hashedFile, false);
    }

    //
    // Adds or updates the hash of an item in a device photo library, filed under the stable source
    // id the library gives it rather than under a path.
    //
    // A library item has no path until it has been copied into the app's sandbox, and that copy is
    // the expensive thing this cache exists to avoid, so a path-keyed entry could only ever be
    // written after paying the cost it was supposed to save. The source id is the identity that
    // exists before the copy, so it is what the entry is filed under.
    //
    pub fn addSourceHash(self: *HashCache, sourceId: []const u8, hashedFile: IHashToCache) !void {
        try self.upsertHash(sourceId, hashedFile, true);
    }

    //
    // Adds or updates a hash in the cache
    //
    fn upsertHash(self: *HashCache, rawKey: []const u8, hashedFile: IHashToCache, keyedBySourceId: bool) !void {
        if (!self.initialized) {
            return errors.throwError("Hash cache not initialized", .{});
        }

        const hash = hashedFile.hash;
        const length = hashedFile.length;
        const lastModified = hashedFile.lastModified;

        if (hash.len != 32) {
            return errors.throwError("Invalid hash length: {d}. Expected 32 bytes.", .{hash.len});
        }

        var arena = std.heap.ArenaAllocator.init(cache_allocator);
        defer arena.deinit();
        const allocator = arena.allocator();
        const key = try normalizeKey(allocator, rawKey);

        const entryOffset = try self.findEntryOffset(allocator, key);
        if (entryOffset >= 0) {
            // Update existing entry
            const buffer = self.buffer.?;
            var offset: usize = @intCast(entryOffset);
            const keyLength = readUInt32LE(buffer, offset);
            offset += 4 + keyLength; // Skip key.
            @memcpy(buffer[offset .. offset + 32], hash[0..32]);
            offset += 32; // Skip hash.
            try writeUInt48LE(buffer, length, offset);
            offset += 6; // Skip size.
            try writeUInt48LE(buffer, lastModified, offset);
            offset += 6; // Skip last modified.
            // The asset id is cleared rather than kept: this call says the file has just been
            // hashed, so whatever id was recorded belongs to the content that was there before.
            try writeAssetId(buffer, offset, null);
            offset += ASSET_ID_BYTES; // Skip asset id.
            buffer[offset] = if (keyedBySourceId) 1 else 0;
            offset += 1; // Skip the source id flag.
        }
        else {
            // Add new entry - need to find insertion point and shift entries
            const insertionIndex: usize = @intCast(-(entryOffset + 1));
            const keyLength = key.len;
            const size = entrySize(keyLength);

            // Ensure we have enough space
            try self.ensureCapacity(size);
            const buffer = self.buffer.?;

            // Get offset where the new entry should be inserted
            var newEntryOffset: i64 = 8; // Entries start at offset 8 after version and entry count headers
            if (insertionIndex > 0) {
                newEntryOffset = try self.getEntryOffsetByIndex(@intCast(insertionIndex - 1));
                if (newEntryOffset >= 0) {
                    const prevKeyLength = readUInt32LE(buffer, @intCast(newEntryOffset));
                    newEntryOffset += @intCast(entrySize(prevKeyLength));
                }
            }

            // Shift all entries after the insertion point
            if (insertionIndex < self.entryCount and newEntryOffset >= 0) {
                const endOffset = try self.getEntryOffsetByIndex(@as(i64, self.entryCount) - 1);
                if (endOffset >= 0) {
                    const lastKeyLength = readUInt32LE(buffer, @intCast(endOffset));
                    const start: usize = @intCast(newEntryOffset);
                    const dataToShift = @as(usize, @intCast(endOffset)) + entrySize(lastKeyLength) - start;
                    std.mem.copyBackwards(u8, buffer[start + size .. start + size + dataToShift], buffer[start .. start + dataToShift]);
                }
            }

            // Write the new entry
            var offset: usize = @intCast(newEntryOffset);
            writeUInt32LE(buffer, @intCast(keyLength), offset);
            offset += 4; // Skip key length.
            @memcpy(buffer[offset .. offset + keyLength], key);
            offset += keyLength; // Skip key.
            @memcpy(buffer[offset .. offset + 32], hash[0..32]);
            offset += 32; // Skip hash.
            try writeUInt48LE(buffer, length, offset);
            offset += 6; // Skip size.
            try writeUInt48LE(buffer, lastModified, offset);
            offset += 6; // Skip last modified.
            try writeAssetId(buffer, offset, null);
            offset += ASSET_ID_BYTES; // Skip asset id.
            buffer[offset] = if (keyedBySourceId) 1 else 0;
            offset += 1; // Skip the source id flag.

            self.entryCount += 1;

            // Update the offset lookup table
            // Only need to adjust offsets after the insertion point
            var newOffsetLookup: std.ArrayList(usize) = .empty;
            try newOffsetLookup.appendSlice(cache_allocator, self.offsetLookup.items[0..insertionIndex]);
            try newOffsetLookup.append(cache_allocator, @intCast(newEntryOffset));

            // Shift all subsequent offsets by entrySize
            for (self.offsetLookup.items[insertionIndex..]) |subsequentOffset| {
                try newOffsetLookup.append(cache_allocator, subsequentOffset + size);
            }

            self.offsetLookup.deinit(cache_allocator);
            self.offsetLookup = newOffsetLookup;
        }

        // Record the change so the next save merges it onto the on-disk cache instead of
        // overwriting entries other instances added. The hash is copied because the caller keeps
        // ownership of the buffer it passed in.
        try self.setPendingUpsert(key, .{
            .key = key,
            .hash = hash[0..32].*,
            .length = length,
            .lastModified = lastModified,
            .assetId = null,
            .keyedBySourceId = keyedBySourceId,
        });
        self.deletePendingRemoval(key);

        self.isDirty = true;
    }

    //
    // Records the id an entry's file has in the database, so the next run knows the file is in
    // there without asking the database at all.
    //
    // Returns false when the cache holds nothing under that key, which is not an error: the entry
    // may have been swept, or written by another process that has not saved yet, and the caller
    // simply pays for one database lookup next time.
    //
    pub fn setAssetId(self: *HashCache, rawKey: []const u8, assetId: []const u8) !bool {
        if (!self.initialized) {
            return false;
        }
        const buffer = self.buffer orelse {
            return false;
        };

        var arena = std.heap.ArenaAllocator.init(cache_allocator);
        defer arena.deinit();
        const allocator = arena.allocator();
        const key = try normalizeKey(allocator, rawKey);

        const entryOffset = try self.findEntryOffset(allocator, key);
        if (entryOffset < 0) {
            return false;
        }

        var offset: usize = @intCast(entryOffset);
        const keyLength = readUInt32LE(buffer, offset);
        offset += 4 + keyLength; // Skip key.
        const hash = buffer[offset..][0..32].*;
        offset += 32; // Skip hash.
        const length = readUInt48LE(buffer, offset);
        offset += 6; // Skip size.
        const lastModified: i64 = @intCast(readUInt48LE(buffer, offset));
        offset += 6; // Skip last modified.
        try writeAssetId(buffer, offset, assetId);
        offset += ASSET_ID_BYTES; // Skip asset id.
        const keyedBySourceId = buffer[offset] == 1;

        // The whole entry goes into the changeset, because the save merges whole entries rather
        // than fields.
        try self.setPendingUpsert(key, .{
            .key = key,
            .hash = hash,
            .length = length,
            .lastModified = lastModified,
            .assetId = assetId,
            .keyedBySourceId = keyedBySourceId,
        });
        self.deletePendingRemoval(key);

        self.isDirty = true;
        return true;
    }

    //
    // Drops every source-keyed entry whose source id is not in the given set, and returns how many
    // went. This is how the cache stops growing forever on a device where photos come and go.
    //
    // Only source-keyed entries are considered. A file path that is not in the photo library is not
    // a dead entry, it is a manual import, and sweeping those would throw away the desktop's whole
    // cache the first time automatic import walked a folder.
    //
    // The caller has to have walked the whole listing before calling this: a partial listing would
    // read as "everything else is gone" and delete the lot.
    //
    // The live ids are put into the form entries are stored in before they are compared, because a
    // source id is often a file path and a watched folder's paths are absolute. Compared raw, a
    // stored "photos/one.jpg" never matched the live "/photos/one.jpg" on Linux or macOS, nor
    // "C:/photos/one.jpg" the live "C:\photos\one.jpg" on Windows, so every entry automatic import
    // had written read as dead and was swept at the end of the very run that wrote it. The desktop
    // and the CLI therefore re-hashed the whole watched folder on every run, while a phone was
    // unaffected because a photo library id has neither a leading slash nor a backslash in it.
    //
    pub fn removeSourceEntriesNotIn(self: *HashCache, liveSourceIds: []const []const u8) !usize {
        var arena = std.heap.ArenaAllocator.init(cache_allocator);
        defer arena.deinit();
        const allocator = arena.allocator();

        var liveKeys: std.StringHashMapUnmanaged(void) = .empty;
        for (liveSourceIds) |liveSourceId| {
            try liveKeys.put(allocator, try normalizeKey(allocator, liveSourceId), {});
        }

        var deadKeys: std.ArrayList([]const u8) = .empty;
        for (try self.getAllEntries(allocator)) |entry| {
            if (entry.keyedBySourceId and !liveKeys.contains(entry.key)) {
                try deadKeys.append(allocator, entry.key);
            }
        }

        for (deadKeys.items) |deadKey| {
            _ = try self.removeHash(deadKey);
        }

        return deadKeys.items.len;
    }

    //
    // Removes a hash from the cache
    //
    // Returns true if the hash was removed, false if it wasn't found
    //
    pub fn removeHash(self: *HashCache, rawKey: []const u8) !bool {
        if (!self.initialized) {
            return false;
        }
        const buffer = self.buffer orelse {
            return false;
        };

        var arena = std.heap.ArenaAllocator.init(cache_allocator);
        defer arena.deinit();
        const allocator = arena.allocator();
        const key = try normalizeKey(allocator, rawKey);

        const entryOffsetValue = try self.findEntryOffset(allocator, key);
        if (entryOffsetValue < 0) {
            return false; // Not found
        }
        const entryOffset: usize = @intCast(entryOffsetValue);

        const keyLength = readUInt32LE(buffer, entryOffset);
        const size = entrySize(keyLength);

        // Shift all entries after this one
        const nextEntryOffset = entryOffset + size;
        if (nextEntryOffset < buffer.len) {
            std.mem.copyForwards(u8, buffer[entryOffset .. entryOffset + (buffer.len - nextEntryOffset)], buffer[nextEntryOffset..]);
        }

        self.entryCount -= 1;
        self.isDirty = true;

        // Record the removal so the next save applies it to the on-disk cache. The key was already
        // put in its stored form above, so it matches the entry that was removed.
        try self.addPendingRemoval(key);
        self.deletePendingUpsert(key);

        // Find the index of the entry that was removed
        const removedIndex = std.mem.indexOfScalar(usize, self.offsetLookup.items, entryOffset) orelse {
            // This should never happen if the code is correct
            return errors.throwError("Removed entry not found in offset lookup table", .{});
        };

        // Remove the entry from the lookup table
        var newOffsetLookup: std.ArrayList(usize) = .empty;
        try newOffsetLookup.appendSlice(cache_allocator, self.offsetLookup.items[0..removedIndex]);

        // Shift all subsequent offsets by -entrySize
        for (self.offsetLookup.items[removedIndex + 1 ..]) |subsequentOffset| {
            try newOffsetLookup.append(cache_allocator, subsequentOffset - size);
        }

        self.offsetLookup.deinit(cache_allocator);
        self.offsetLookup = newOffsetLookup;

        return true;
    }

    //
    // Gets the number of entries in the cache
    //
    pub fn getEntryCount(self: *const HashCache) u32 {
        return self.entryCount;
    }

    //
    // Gets all entries from the cache
    // (Zig: the keys, hashes and asset ids are copied into the allocator.)
    //
    pub fn getAllEntries(self: *HashCache, allocator: std.mem.Allocator) ![]IHashCacheListing {
        var entries: std.ArrayList(IHashCacheListing) = .empty;

        const buffer = self.buffer orelse {
            return entries.items;
        };
        if (self.entryCount == 0) {
            return entries.items;
        }

        var index: u32 = 0;
        while (index < self.entryCount) : (index += 1) {
            const offset = try self.getEntryOffsetByIndex(index);
            if (offset < 0) {
                continue;
            }

            var currentOffset: usize = @intCast(offset);
            const keyLength = readUInt32LE(buffer, currentOffset);
            currentOffset += 4;

            const key = try allocator.dupe(u8, buffer[currentOffset .. currentOffset + keyLength]);
            currentOffset += keyLength;

            const hash = try allocator.dupe(u8, &std.fmt.bytesToHex(buffer[currentOffset..][0..32].*, .lower));
            currentOffset += 32;

            const size = readUInt48LE(buffer, currentOffset);
            currentOffset += 6;

            const lastModified: i64 = @intCast(readUInt48LE(buffer, currentOffset));
            currentOffset += 6;

            const assetId = if (readAssetId(buffer, currentOffset)) |id| try allocator.dupe(u8, id) else null;
            currentOffset += ASSET_ID_BYTES;

            const keyedBySourceId = buffer[currentOffset] == 1;

            try entries.append(allocator, .{
                .key = key,
                .hash = hash,
                .size = size,
                .lastModified = lastModified,
                .assetId = assetId,
                .keyedBySourceId = keyedBySourceId,
            });
        }

        return entries.items;
    }
};

//
// A read-only hash cache already in hand, and what the file it came from looked like when it was
// read.
//
const ILoadedHashCache = struct {
    // The cache itself, loaded and ready to be asked for a hash.
    cache: *HashCache,

    // The size of the cache file when it was read, in bytes (-1 when there was no file).
    fileLength: i64,

    // When the cache file was last modified when it was read (nanoseconds since the epoch, finer than the
    // TypeScript's fractional milliseconds; -1 when there was no file).
    fileLastModified: i128,
};

//
// The read-only cache held for each directory, so a second reader of the same cache does not read
// the file again.
// (Zig: kept per thread. Each TypeScript worker has its own module state, and each Zig worker is a thread.)
//
threadlocal var loadedHashCaches: std.StringHashMapUnmanaged(ILoadedHashCache) = .empty;

//
// Returns a read-only hash cache for a directory, reading the file only when it has changed.
//
// Loading a hash cache reads and decodes the whole file, and hashing a file asked for a fresh one
// per file. The cost of that grows with the cache, and an import puts every photo it has already
// done into the cache, so the price per photo rose as the import went on: on a Pixel 6 against a
// real library it was 210ms a photo at four hundred photos and 651ms at sixteen hundred, which is
// most of what made a long import slow down the longer it ran.
//
// The file's length and modification time are what decide whether the copy in hand is still the
// file. Anything written by this process or another one changes both, so a writer's entries are
// picked up; a change too small and too quick to move either only costs the reader a hash it could
// have found, which is the same answer it would have given before the entry was written.
//
pub fn loadSharedHashCache(io: std.Io, cacheDir: []const u8) !*HashCache {
    var arena = std.heap.ArenaAllocator.init(cache_allocator);
    defer arena.deinit();
    const cachePath = try path.join(arena.allocator(), &.{ cacheDir, "hash-cache-x.dat" });

    var fileLength: i64 = -1;
    var fileLastModified: i128 = -1;
    if (pathExists(io, cachePath)) {
        const cacheFileStat = try std.Io.Dir.cwd().statFile(io, cachePath, .{});
        fileLength = @intCast(cacheFileStat.size);
        fileLastModified = cacheFileStat.mtime.nanoseconds;
    }

    const alreadyLoaded = loadedHashCaches.get(cacheDir);
    if (alreadyLoaded != null and alreadyLoaded.?.fileLength == fileLength and alreadyLoaded.?.fileLastModified == fileLastModified) {
        return alreadyLoaded.?.cache;
    }

    const cache = try cache_allocator.create(HashCache);
    errdefer cache_allocator.destroy(cache);
    cache.* = try HashCache.init(cacheDir, true);
    errdefer cache.deinit();
    _ = try cache.load(io);

    if (loadedHashCaches.getEntry(cacheDir)) |existing| {
        // The copy this thread held before is no longer handed out: the task that used it has finished.
        existing.value_ptr.cache.deinit();
        cache_allocator.destroy(existing.value_ptr.cache);
        existing.value_ptr.* = .{
            .cache = cache,
            .fileLength = fileLength,
            .fileLastModified = fileLastModified,
        };
    }
    else {
        try loadedHashCaches.put(cache_allocator, try cache_allocator.dupe(u8, cacheDir), .{
            .cache = cache,
            .fileLength = fileLength,
            .fileLastModified = fileLastModified,
        });
    }

    return cache;
}

//
// Forgets every cache held, so the next reader loads from the file again.
//
// Exported for tests, which need each one to start from nothing rather than from what the test
// before it left behind. (Zig: forgets the caches of the calling thread.)
//
pub fn forgetSharedHashCaches() void {
    var iterator = loadedHashCaches.iterator();
    while (iterator.next()) |entry| {
        entry.value_ptr.cache.deinit();
        cache_allocator.destroy(entry.value_ptr.cache);
        cache_allocator.free(entry.key_ptr.*);
    }
    loadedHashCaches.clearRetainingCapacity();
}
