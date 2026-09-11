import { log, retry } from "utils";
import { IStorage } from "./storage";
import { pathJoin } from "./storage-factory";

//
// How long one page of a directory listing is allowed to take, in milliseconds.
//
// `retry`'s default of thirty seconds was what applied, and a walk of a real database's index
// directories failed on it: measured on a Pixel 6 filling in a partial replica of an 8,231-photo
// database, a pass ran for 35 minutes 30 seconds, fetched 8,231 thumbnails and 106 of the 116
// missing index files, and then ended on "Operation timed out after 30000ms: () =>
// storage.listDirs(dirPath, 1000, next)".
//
// The listing was not slow. The walk runs interleaved with the copies it feeds, and on the phone
// those copies block the embedded engine's thread inside synchronous host calls: the failing task
// reported 193 seconds of run time with 81 milliseconds of pumping and 14 of waiting for events, so
// for most of those three minutes no JavaScript ran at all. A wall-clock timeout then measures time
// the listing was never given, and all three of `retry`'s attempts expired inside the same 80
// milliseconds, one after another, without the listing having had a chance between them.
//
// So this is slack for an engine that stops running JavaScript while it moves bytes, not an estimate
// of how long a listing takes. It is minutes rather than the ninety of LARGE_FILE_TIMEOUT because a
// listing that genuinely never answers should still be given up on inside a pass rather than holding
// one open for an hour and a half.
//
const DIRECTORY_LISTING_TIMEOUT = 5 * 60 * 1_000;

/**
 * Represents a file that has been ordered by where it was found in the file system.
 */
export interface IOrderedFile {
    fileName: string;
}

/**
 * Recursively walks a directory structure and adds file paths to the provided queue
 * @param dirPath Directory path to start walking from
 * @param queue Queue to add file paths to
 * @param ignorePatterns RegExp patterns to ignore
 */
export async function* walkDirectory(
    storage: IStorage,
    dirPath: string,
    ignorePatterns: RegExp[] = [/node_modules/, /\.git/, /\.DS_Store/]
): AsyncGenerator<IOrderedFile> {
    let next: string | undefined = undefined;
    do {
        const fileBatch = await retry(() => storage.listFiles(dirPath, 1000, next), 3, 1_000, 2, DIRECTORY_LISTING_TIMEOUT, `Failed to list the files in ${dirPath}`);
        for (const fileName of fileBatch.names) {
            let fullPath = pathJoin(dirPath, fileName);

            // Check if path matches any ignore patterns
            const shouldIgnore = ignorePatterns.some(pattern => pattern.test(fullPath));
            if (shouldIgnore) {
                log.verbose(`Ignoring ${fullPath}`);
                continue;
            }

            yield {
                fileName: fullPath,
            };
        }

        next = fileBatch.next;

    } while (next);

    next = undefined;
    do {
        const dirBatch = await retry(() => storage.listDirs(dirPath, 1000, next), 3, 1_000, 2, DIRECTORY_LISTING_TIMEOUT, `Failed to list the directories in ${dirPath}`);
        for (const dirName of dirBatch.names) {
            let fullPath = pathJoin(dirPath, dirName);

            // Check if path matches any ignore patterns
            const shouldIgnore = ignorePatterns.some(pattern => pattern.test(fullPath));
            if (shouldIgnore) {
                log.verbose(`Ignoring ${fullPath}`);
                continue;
            }

            // Recursively walk subdirectories
            yield* walkDirectory(storage, fullPath, ignorePatterns);
        }

        next = dirBatch.next;

    } while (next);
    
}
