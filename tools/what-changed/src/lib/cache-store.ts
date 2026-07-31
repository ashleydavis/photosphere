import { mkdir, readFile, rename, writeFile } from "node:fs/promises";
import * as path from "node:path";
import { FileHashCache } from "./file-hash";

//
// The name of the file holding the per-file content hashes.
//
const FILE_HASHES_NAME = "file-hashes.json";

//
// The name of the file holding what each target saw the last time it passed.
//
const TARGET_HASHES_NAME = "target-hashes.json";

//
// The name of the file holding every file's content hash as of the last run that passed. This is the
// baseline "what has changed" is measured against, and it is separate from FILE_HASHES_NAME because
// that one is an optimisation refreshed on every run, including runs that failed.
//
const PASSED_FILE_HASHES_NAME = "passed-file-hashes.json";

//
// Maps a watched relative path to its hash at the moment a target last passed.
//
export interface PathHashes {
    [watchedPath: string]: string;
}

//
// Maps a target name to what that target saw the last time it passed.
//
export interface TargetHashes {
    [targetName: string]: PathHashes;
}

//
// Maps a repository-relative path to its content hash as of the last run that passed.
//
export interface PassedFileHashes {
    [relativePath: string]: string;
}

//
// Everything the gate remembers between runs.
//
export interface GateCache {
    //
    // The per-file hashes, so unchanged files are never read again.
    //
    fileHashes: FileHashCache;

    //
    // The watched-path hashes recorded when each target last passed.
    //
    targetHashes: TargetHashes;

    //
    // Every file's content hash as of the last run that passed, which is what a change is measured
    // against. Empty until a run has passed.
    //
    passedFileHashes: PassedFileHashes;
}

//
// Loads the cache from disk. A missing directory, a missing file, or JSON that will not parse or is
// the wrong shape all yield empty structures rather than an error: a damaged cache should cost a slow
// run, never a blocked one.
//
export async function loadCache(cacheDir: string): Promise<GateCache> {
    return {
        fileHashes: await readJsonObject(path.join(cacheDir, FILE_HASHES_NAME)),
        targetHashes: await readJsonObject(path.join(cacheDir, TARGET_HASHES_NAME)),
        passedFileHashes: await readJsonObject(path.join(cacheDir, PASSED_FILE_HASHES_NAME)),
    };
}

//
// Reads a JSON object from a file, returning an empty object for anything that is not a readable,
// parseable, plain JSON object.
//
export async function readJsonObject(filePath: string): Promise<any> {
    let text: string;
    try {
        text = await readFile(filePath, "utf8");
    }
    catch (err) {
        return {};
    }

    let parsed: any;
    try {
        parsed = JSON.parse(text);
    }
    catch (err) {
        return {};
    }

    if (typeof parsed !== "object" || parsed === null || Array.isArray(parsed)) {
        return {};
    }
    return parsed;
}

//
// Writes the per-file hashes, creating the cache directory if it is not there yet.
//
export async function saveFileHashes(cacheDir: string, fileHashes: FileHashCache): Promise<void> {
    await writeJsonObject(cacheDir, FILE_HASHES_NAME, fileHashes);
}

//
// Writes the per-target hashes, creating the cache directory if it is not there yet.
//
export async function saveTargetHashes(cacheDir: string, targetHashes: TargetHashes): Promise<void> {
    await writeJsonObject(cacheDir, TARGET_HASHES_NAME, targetHashes);
}

//
// Writes a JSON file through a temporary sibling and a rename, so a crash part way through a write
// cannot leave a half-written file behind for the next run to choke on.
//
export async function writeJsonObject(cacheDir: string, fileName: string, value: any): Promise<void> {
    await mkdir(cacheDir, { recursive: true });
    const finalPath = path.join(cacheDir, fileName);
    const tempPath = `${finalPath}.tmp`;
    await writeFile(tempPath, JSON.stringify(value, null, 2), "utf8");
    await rename(tempPath, finalPath);
}

//
// Writes the content hashes of the tree that just passed, creating the cache directory if needed.
//
export async function savePassedFileHashes(cacheDir: string, passedFileHashes: PassedFileHashes): Promise<void> {
    await writeJsonObject(cacheDir, PASSED_FILE_HASHES_NAME, passedFileHashes);
}

//
// Returns a copy of the file hash cache holding only the paths that still exist, so entries for
// deleted files do not accumulate for the life of the checkout.
//
export function pruneFileHashes(fileHashes: FileHashCache, currentPaths: string[]): FileHashCache {
    const keep = new Set(currentPaths);
    const pruned: FileHashCache = {};
    for (const [relativePath, entry] of Object.entries(fileHashes)) {
        if (keep.has(relativePath)) {
            pruned[relativePath] = entry;
        }
    }
    return pruned;
}
