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
