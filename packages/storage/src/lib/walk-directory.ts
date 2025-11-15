import { log } from "utils";
import { IStorage } from "./storage";
import { pathJoin } from "./storage-factory";

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
        const fileBatch = await storage.listFiles(dirPath, 1000, next);
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
        const dirBatch = await storage.listDirs(dirPath, 1000, next);
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
