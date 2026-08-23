import { IUuidGenerator } from "utils";
import { ScannerOptions, ScanProgressCallback, scanPaths } from "./file-scanner";
import { IImportScanner, IScannedImportFile } from "./import-scanner";

//
// The scanner for an import the user asked for: a fixed list of files and folders, walked once.
//
// This is exactly what `import-assets` did inline before there was a scanner at all, moved behind
// the interface and nothing else. It has to stay that way: manual import is the most used path in
// the application, and the CLI and Electron import smoke tests are what prove it did not change.
//
export class ManualImportScanner implements IImportScanner {
    //
    // The files and folders to walk.
    //
    private readonly paths: string[];

    //
    // What the scan ignores, and where it unpacks a zip to.
    //
    private readonly options: ScannerOptions;

    //
    // The directory a zip's contents are extracted into.
    //
    private readonly sessionTempDir: string;

    //
    // Names the temporary files extracted from a zip.
    //
    private readonly uuidGenerator: IUuidGenerator;

    constructor(paths: string[], options: ScannerOptions, sessionTempDir: string, uuidGenerator: IUuidGenerator) {
        this.paths = paths;
        this.options = options;
        this.sessionTempDir = sessionTempDir;
        this.uuidGenerator = uuidGenerator;
    }

    //
    // Walks the paths once and returns, which is what ends the import.
    //
    async scan(visitFile: (result: IScannedImportFile) => Promise<void>, onProgress: ScanProgressCallback): Promise<void> {
        await scanPaths(
            this.paths,
            // No cache identity: a file the user picked is identified by its own path, exactly as it
            // always was. Only a photo library item needs anything else.
            result => visitFile({ ...result, cacheIdentity: undefined }),
            onProgress,
            this.options,
            this.sessionTempDir,
            this.uuidGenerator
        );
    }

    //
    // Nothing to release. These files were already files before the import looked at them, and a
    // file the user asked to import is not the import's to delete.
    //
    async release(_filePath: string): Promise<void> {
    }
}
