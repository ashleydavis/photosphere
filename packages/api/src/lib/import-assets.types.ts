import { IAsset } from "./asset";
import { ImportSource } from "./import-record";

//
// What an import run reports back to whoever asked for it.
//
// These live here rather than beside the import task itself because automatic import reads them on
// both sides of the divide: from a worker on the CLI and the desktop, and from the WebView on
// mobile, where the import runs in the embedded engine and the loop that drives it does not.
//

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
export interface IFileCacheIdentity {
    // What the cache entry is filed under: the item's stable source id.
    key: string;

    // The size of the item in bytes, as the listing reports it.
    length: number;

    // The item's created time in milliseconds since the epoch, as the listing reports it. Compared
    // against the entry's modified time, which for a source-keyed entry is this same value: the
    // temporary copy's own modified time is minted by the copy and matches nothing.
    lastModified: number;
}

//
// One asset the import added to the database.
//
export interface IImportedAsset {
    // The id the asset was given in the database.
    assetId: string;

    // The path the asset was imported from.
    logicalPath: string;

    // The asset record that was written, so a caller can show the asset without reloading.
    asset: IAsset;
}

//
// One file the import found was already in the database.
//
export interface ISkippedImport {
    // The path the file was read from.
    logicalPath: string;

    // The content hash of the file, lower-case hex. Carried so a caller can confirm the file really
    // is the one the database holds, rather than taking "skipped" on trust.
    contentHash: string;
}

//
// What an import run did.
//
// This is returned as well as sent as messages because a task running in a worker can see a child
// task's result but not its messages: the worker pool broadcasts completions back to the workers and
// keeps messages for the main process. An orchestrator such as auto-import therefore has to read the
// outcome from here.
//
export interface IImportAssetsResult {
    // The assets that were added to the database.
    imported: IImportedAsset[];

    // The files that were already in the database.
    skipped: ISkippedImport[];

    // How many files could not be imported.
    failedCount: number;

    // Where the run's time went, so an import can be measured rather than guessed at.
    timings: IImportTimings;
}

//
// Where an import run's time went, and how much work it did.
//
// Hashing is broken out on its own because it is the stage a native hash replaces, and because the
// question a measurement of this has to answer is not whether hashing got faster, which is easy, but
// whether the import as a whole did. Reported for every import rather than only a measured one: an
// import that is slow on a user's phone is worth being able to account for, and the counters cost
// two clock reads per file against work measured in seconds per file.
//
export interface IImportTimings {
    // Wall clock for the whole run, from the first file being looked at to the last database write.
    // This is the figure a person waiting for their photos experiences, and the one a change has to
    // move to be worth keeping.
    totalMs: number;

    // Time spent inside the hashing step, summed over every file that was hashed.
    //
    // Summed across child tasks that run concurrently, so it is not a slice of totalMs and must never
    // be reported as a percentage of it. Compare it against childTaskMs, which is summed the same way.
    hashMs: number;

    // Time spent asking the hash cache about a file, summed over every file, hit or miss.
    cacheLookupMs: number;

    // Time spent loading the hash cache, paid once per file by every hash-file task.
    cacheLoadMs: number;

    // Time spent in every child task the import ran, summed the same way as hashMs. This is what
    // hashMs is a share of.
    childTaskMs: number;

    // How many files were hashed, because the cache did not already know them.
    filesHashed: number;

    // How many files the cache answered for once the import had already opened them, so no hashing
    // was needed.
    filesFromCache: number;

    // How many items the scanner recognised before opening them at all, from what the hash cache
    // already knew about the item's source id, size and created time.
    //
    // This is the whole of the work on a run over a library that has already been imported, and it
    // is why such a run costs almost nothing: an item answered here is never copied out of the photo
    // library and never hashed, so every other counter here stays at zero. A measurement that did
    // not report it would show a warm run as having done nothing at all.
    skippedBeforeOpening: number;

    // How many bytes were hashed. The rate that carries across libraries is bytes per second, not
    // files per second, because one library's photos are not another's size.
    bytesHashed: number;

    // Time spent copying items out of the device photo library, summed over every item copied. On a
    // phone an item has no path until it has been copied into the app's sandbox, so this is paid
    // before anything can read it.
    exportMs: number;

    // Time spent reading an item's own metadata: the EXIF block on a photo, the probe on a video.
    //
    // Split by kind because they are different problems with different fixes: a photo pays to have
    // its EXIF read, and a video pays to have a frame decoded out of it to make a thumbnail from.
    photoMetadataMs: number;
    videoMetadataMs: number;
    metadataMs: number;

    // Time spent producing the micro thumbnail, the thumbnail and the display version. Reported
    // apart from each other because each is a separate decode of the full size original today, so
    // whether they are worth merging is a question the numbers have to answer.
    microMs: number;
    thumbnailMs: number;
    displayMs: number;

    // Time spent writing the original and its derivatives into storage.
    uploadMs: number;

    // Time spent asking a geocoding service where a photo was taken. Only photos carrying
    // coordinates cost anything here, and only when a key is configured.
    geocodeMs: number;

    // Time spent working out an asset's dominant colour from its thumbnail.
    dominantColorMs: number;

    // Time inside a child task that none of the other counters name, and the media tool probe.
    otherMs: number;
    probeMs: number;

    // Opening storage, once per child task.
    openStorageMs: number;

    // Time spent writing a batch of finished assets to the database under the write lock.
    databaseWriteMs: number;

    // What that write time was spent on, and how many batches it was spread over.
    //
    // Broken out because the whole merkle tree is loaded and saved on every batch, so a run that
    // writes in small batches pays for the whole tree over and over. The batch count is what makes
    // that visible: the same total means something very different over five batches than over five
    // hundred.
    databaseBatches: number;
    databaseFlushMs: number;
    databaseLockWaitMs: number;
    databaseTreeLoadMs: number;
    databaseAddItemsMs: number;

    // That loop split three ways: the merkle tree adds, the record inserts with their sort indexes,
    // and the rest of what the loop does per item.
    databaseMerkleAddMs: number;
    databaseRecordInsertMs: number;

    // That insert split again: the collection insert, and the hash cache entry the asset id is
    // written into.
    databaseCollectionInsertMs: number;
    databaseHashCacheAssetIdMs: number;
    databasePerItemOtherMs: number;
    databaseTreeSaveMs: number;
    databaseCommitMs: number;
    databaseStampMs: number;

    // The writes underneath the database work: how many, how many bytes, and how long the platform
    // spent taking them.
    databaseWrites: number;
    databaseWriteBytes: number;
    databaseWriteCallMs: number;

    // How many photos and how many videos the run dealt with. Kept apart because a stage that is
    // slow only for video is a different problem from one that is slow for everything, and a
    // library's mix of the two is what decides which of those matters.
    photosSeen: number;
    videosSeen: number;
}

//
// Streamed once per asset an import adds, so the gallery can show photos landing one at a time
// without reloading the database.
//
// One message covers both kinds of import. There used to be a second one for automatic arrivals,
// carrying nothing the first did not except the database path, which meant every automatically
// imported photo was announced twice and the gallery had to refuse the duplicate.
//
export interface IImportSuccessMessage {
    // Discriminator matched by onTaskMessage("import-success").
    type: "import-success";

    // The database the asset was added to.
    //
    // Automatic import writes to the default database, which is not necessarily the one the user is
    // looking at. Without this the gallery takes every arrival as its own: a photo landing in another
    // database appears in this one, and a photo landing in this one appears twice, once from the
    // arrival and once from the load that follows.
    databasePath: string;

    // The id the asset was given in the database.
    assetId: string;

    // The path the asset was imported from.
    logicalPath: string;

    // Whether the user asked for this import or it arrived on its own. The gallery marks an arrival
    // it did not ask for, so it can be shown landing; one the user is watching happen needs no mark.
    source: ImportSource;

    // The asset's micro thumbnail, so something can be shown before the image itself loads.
    micro: string;

    // The asset record, so the gallery can show it without reloading the database.
    asset: IAsset;
}

//
// Streamed as an import works, so the interface can show what is happening without waiting for the
// run to end.
//
// One message covers both kinds of import. There used to be a second one that only an automatic
// import sent, carrying the same counts plus how far through the photo library it was.
//
export interface IImportProgressMessage {
    // Discriminator matched by onTaskMessage("import-progress").
    type: "import-progress";

    // How many items the run has dealt with, whether it imported them or recognised them as already
    // imported.
    seen: number;

    // How many items were added to the database.
    imported: number;

    // How many items were already in the database: the ones recognised before the file was even
    // opened, as well as the ones the hashing recognised.
    skipped: number;

    // How many items could not be imported.
    failed: number;

    // The item the run is working on, for the interface to name.
    currentItem: string | undefined;
}

//
// Sent once, as an import run ends, carrying where its time went.
//
// A message rather than only a log line because on mobile the import runs inside the embedded JS
// engine, whose own log output never reaches the app log. Progress reaches the WebView this way and
// nothing else does, so a measurement that was only logged would be written where nobody can read
// it. Sent whether the run finished, failed or was stopped part way, because a measurement of a
// photo library too big to import in one sitting is a run that was stopped on purpose.
//
export interface IImportTimingsMessage {
    // Discriminator matched by onTaskMessage("import-timings").
    type: "import-timings";

    // Where the run's time went.
    timings: IImportTimings;
}
