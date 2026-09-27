//
// What an import run reports back to whoever asked for it.
//
// These live here rather than beside the import task itself because automatic import reads them on
// both sides of the divide: from a worker on the CLI and the desktop, and from the WebView on
// mobile, where the import runs in the embedded engine and the loop that drives it does not.
//

const serialization_zig = @import("serialization-zig");
const BsonDocument = serialization_zig.bson.BsonDocument;

//
// How one file being imported is identified in the hash cache.
//
// The import normally files a hashed file under its own path, which is fine for a folder on a
// desktop machine where the path is what the file is. It is useless for a device photo library: an
// item there has no path at all until it has been copied into the app's sandbox, and that copy is
// the expensive thing the cache exists to avoid, so a path-keyed entry could only ever be written
// after paying the cost it was supposed to save, and the copy is deleted straight afterwards.
//
// So automatic import supplies this instead: the source id the library gives the item, which does
// not change between listings, along with the size and created time the listing reports. All three
// are compared on lookup, because a photo library is free to reuse an id once the item it named has
// been deleted, and a stale hit there would skip a photo that was never imported.
//
pub const IFileCacheIdentity = struct {
    // What the cache entry is filed under: the item's stable source id.
    key: []const u8,

    // The size of the item in bytes, as the listing reports it.
    length: u64,

    // The item's created time in milliseconds since the epoch, as the listing reports it. Compared
    // against the entry's modified time, which for a source-keyed entry is this same value: the
    // temporary copy's own modified time is minted by the copy and matches nothing.
    lastModified: i64,
};

//
// One asset the import added to the database.
//
pub const IImportedAsset = struct {
    // The id the asset was given in the database.
    assetId: []const u8,

    // The path the asset was imported from.
    logicalPath: []const u8,

    // The asset record that was written, so a caller can show the asset without reloading.
    // (Zig: an asset record is the BSON document stored in the database.)
    asset: BsonDocument,
};

//
// One file the import found was already in the database.
//
pub const ISkippedImport = struct {
    // The path the file was read from.
    logicalPath: []const u8,

    // The content hash of the file, lower-case hex. Carried so a caller can confirm the file really
    // is the one the database holds, rather than taking "skipped" on trust.
    contentHash: []const u8,
};

//
// What an import run did.
//
// This is returned as well as sent as messages because a task running in a worker can see a child
// task's result but not its messages: the worker pool broadcasts completions back to the workers and
// keeps messages for the main process. An orchestrator such as auto-import therefore has to read the
// outcome from here.
//
pub const IImportAssetsResult = struct {
    // The assets that were added to the database.
    imported: []const IImportedAsset,

    // The files that were already in the database.
    skipped: []const ISkippedImport,

    // How many files could not be imported.
    failedCount: u64,
};

// Not ported: IImportSuccessMessage, IImportProgressMessage as types (the import sends them as the
// JSON objects task messages are in Zig; see import-assets.worker.zig in node-api-zig).
