//
// Reset-app-storage worker handler.
//
// Empties the two directories the app keeps its own files in: the config directory (the databases
// list, the desktop settings, the automatic-import and sync settings, the news state) and the cache
// directory (the hash caches and the import records). The directories themselves are left in place,
// so the app writes into them again exactly as it did on a fresh install.
//
// This is what "reset device" deletes, and on a phone it is what removes the databases: a local
// database path on mobile is a name inside the app's storage sandbox, and getConfigDir() and
// getCacheDir() both answer that sandbox root there, so every database the app created goes with it.
// On desktop those two are the config and cache directories under the user's home, which hold only
// the app's own files, so a database at a path the user chose is left exactly where it is.
//
// The handler takes no input naming a path, deliberately. A task that accepted "delete this
// directory" would be one bad caller away from deleting somebody's photo library, and nothing in the
// type system would catch it. The only paths it can ever reach are the two it reads for itself.
//
// Runs on both platforms via the shared task queue: desktop, the CLI and the dev server register it
// through initTaskHandlers and mobile through mobile-worker-entry. On mobile every delete goes
// through the worker's fs shims, which resolve inside the app's storage sandbox and refuse to leave
// it, so the boundary holds even if this code is wrong.
//

import * as fs from "fs/promises";
import * as path from "path";
import type { ITaskContext } from "task-queue";
import { getConfigDir, getCacheDir, pathExists, remove } from "node-utils";

//
// Result of the reset-app-storage task.
//
export interface IResetAppStorageResult {
    //
    // The directories that were emptied. One entry on a device, where the config and the cache are
    // both the app's storage sandbox; two on desktop.
    //
    directoriesCleared: string[];

    //
    // How many entries (files and directory trees) were removed across those directories.
    //
    entriesRemoved: number;
}

//
// Empties one directory, returning how many entries it removed. A directory that does not exist has
// nothing to remove and is not an error: an app that has never written a cache still resets.
//
async function clearDirectory(directoryPath: string): Promise<number> {
    if (!await pathExists(directoryPath)) {
        return 0;
    }

    const entryNames = await fs.readdir(directoryPath);
    for (const entryName of entryNames) {
        await remove(path.join(directoryPath, entryName));
    }
    return entryNames.length;
}

//
// Handler for the reset-app-storage task. Empties the app's config and cache directories and reports
// what it removed.
//
export async function resetAppStorageHandler(_data: object, _context: ITaskContext): Promise<IResetAppStorageResult> {
    // Deduplicated because on a device both answer the storage sandbox root. Emptying the same
    // directory twice would count everything in it once and then find nothing, reporting a number
    // that does not match what went.
    const directoryPaths: string[] = [];
    for (const directoryPath of [getConfigDir(), getCacheDir()]) {
        const normalized = path.normalize(directoryPath);
        if (!directoryPaths.includes(normalized)) {
            directoryPaths.push(normalized);
        }
    }

    let entriesRemoved = 0;
    for (const directoryPath of directoryPaths) {
        entriesRemoved += await clearDirectory(directoryPath);
    }

    return {
        directoriesCleared: directoryPaths,
        entriesRemoved,
    };
}
