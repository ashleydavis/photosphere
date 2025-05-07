import { IStorage, pathJoin } from "storage";

//
// Represents a directory.
//
export interface IDirectory {
    name: string;
    directory?: IDirectory;
}

/**
 * Represents a file that has been ordered by where it was found in the file system.
 */
export interface IOrderedFile {
    fileName: string;
    directory?: IDirectory;
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
    directory?: IDirectory,
    ignorePatterns: RegExp[] = [/node_modules/, /\.git/, /\.DS_Store/]
): AsyncGenerator<IOrderedFile> {
    let next: string | undefined = undefined;
    do {
        const fileBatch = await storage.listFiles(dirPath, 1000, next);
        for (const fileName of fileBatch.names) {
            const fullPath = pathJoin(dirPath, fileName);

            // Check if path matches any ignore patterns
            const shouldIgnore = ignorePatterns.some(pattern => pattern.test(fullPath));
            if (shouldIgnore) {
                console.log(`Ignoring ${fullPath}`);
                continue;
            }

            yield {
                fileName,
                directory,
            };
        }

        next = fileBatch.next;

    } while (next);

    next = undefined;
    do {
        const dirBatch = await storage.listDirs(dirPath, 1000, next);
        for (const dirName of dirBatch.names) {
            const fullPath = pathJoin(dirPath, dirName);

            // Check if path matches any ignore patterns
            const shouldIgnore = ignorePatterns.some(pattern => pattern.test(fullPath));
            if (shouldIgnore) {
                console.log(`Ignoring ${fullPath}`);
                continue;
            }

            // Recursively walk subdirectories
            yield* walkDirectory(storage, fullPath, { name: dirName, directory }, ignorePatterns);
        }

        next = dirBatch.next;

    } while (next);
    
}
