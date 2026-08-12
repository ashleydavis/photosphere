import { IAsset } from "./asset";

//
// What an import run reports back to whoever asked for it.
//
// These live here rather than beside the import task itself because automatic import reads them on
// both sides of the divide: from a worker on the CLI and the desktop, and from the WebView on
// mobile, where the import runs in the embedded engine and the loop that drives it does not.
//

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
