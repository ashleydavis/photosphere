//
// Extends the standard File interface with an optional test-injected filesystem path.
// Set by the shared test driver's drop command, which cannot construct a File that has a real path.
//
export interface IDroppedFile extends File {
    // The path a test says the file has.
    __testPath?: string;
}

//
// Works out the real path of a dropped file. In test mode a path the test attached to the file wins. Otherwise the
// bridge is asked, on a desktop, where a dropped file has a path, and a phone, which has no drop, answers undefined.
//
export function resolveDroppedFilePath(file: IDroppedFile, testMode: boolean, isDesktop: boolean, getPathFromBridge: (file: File) => string | undefined): string | undefined {
    if (testMode && file.__testPath) {
        return file.__testPath;
    }
    if (!isDesktop) {
        return undefined;
    }
    return getPathFromBridge(file);
}
