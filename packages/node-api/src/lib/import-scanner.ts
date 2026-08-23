import { IFileCacheIdentity } from "api/src/lib/import-assets.types";
import { FileScannedResult, ScanProgressCallback } from "./file-scanner";

//
// One file a scanner is offering to the import.
//
// It is a scanned file plus, for a photo library item, what that file really is. The file itself is
// a temporary copy with a path and a modified time that were both minted by the copy, so it is the
// identity rather than the path that the hash is filed under. See IFileCacheIdentity.
//
export interface IScannedImportFile extends FileScannedResult {
    // What this file is identified as in the hash cache, or undefined when its own path identifies
    // it, which is the case for every file a manual import walks.
    cacheIdentity: IFileCacheIdentity | undefined;
}

//
// Where the files an import takes in come from.
//
// The import orchestrator does not know whether it is importing a folder the user picked or a photo
// library it is watching. It asks a scanner to push files at it and takes what it is given, which is
// what lets one long-lived `import-assets` task serve both.
//
// This is deliberately the same call the orchestrator already made to `scanPaths`: a per-file
// callback that is awaited, and a progress callback. Nothing was invented for it, so the change in
// the orchestrator is the one line that used to call `scanPaths` directly.
//
// There is no "nothing right now" and no "exhausted". A paced scanner simply does not call back
// until its budget allows, and a finite one returns when its walk is done.
//
export interface IImportScanner {
    //
    // Pushes every file this scanner has, one at a time, and returns when there are no more.
    //
    // A scanner that watches somewhere for new files does not return until the import is cancelled,
    // which is the one genuine difference between the two kinds.
    //
    scan(visitFile: (result: IScannedImportFile) => Promise<void>, onProgress: ScanProgressCallback): Promise<void>;

    //
    // Releases whatever the scanner materialised for one file, once the import has finished with it.
    //
    // A folder's files are already files and there is nothing to release. A photo library item is
    // not a file at all: it had to be copied into the app's sandbox to be read, and that copy is
    // deleted here. Called for every file the scanner pushed, whatever the import made of it.
    //
    release(filePath: string): Promise<void>;
}
