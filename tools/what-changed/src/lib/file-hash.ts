import { createHash } from "node:crypto";
import { readFile, stat } from "node:fs/promises";
import * as path from "node:path";

//
// Stands in for a digest when a file disappeared between being listed and being hashed. A deleted
// file has to hash to something stable so that the tree above it changes when the file goes away.
//
export const MISSING_FILE_HASH = "<missing>";

//
// What is remembered about one file so it does not have to be read again.
//
export interface FileHashEntry {
    //
    // The file's modification time in milliseconds when the hash was computed.
    //
    mtimeMs: number;

    //
    // The file's size in bytes when the hash was computed.
    //
    size: number;

    //
    // The SHA-256 hex digest of the file's content.
    //
    hash: string;
}

//
// Maps a repository-relative path to what was last known about that file. Paths are relative so the
// cache stays valid when the checkout moves.
//
export interface FileHashCache {
    [relativePath: string]: FileHashEntry;
}

//
// Returns the SHA-256 hex digest of one file's content, reading the file only when the cached entry
// no longer matches the file's modification time and size.
//
export async function hashFile(rootDir: string, relativePath: string, cache: FileHashCache): Promise<string> {
    const fullPath = path.join(rootDir, relativePath);

    let stats;
    try {
        stats = await stat(fullPath);
    }
    catch (err: any) {
        if (err.code === "ENOENT") {
            return MISSING_FILE_HASH;
        }
        throw err;
    }

    const cached = cache[relativePath];
    if (cached && cached.mtimeMs === stats.mtimeMs && cached.size === stats.size) {
        return cached.hash;
    }

    const content = await readFile(fullPath);
    const hash = createHash("sha256").update(content).digest("hex");
    cache[relativePath] = {
        mtimeMs: stats.mtimeMs,
        size: stats.size,
        hash,
    };
    return hash;
}

//
// Hashes every requested file, sharing one cache across the whole set. Sequential on purpose: in the
// steady state this is one stat per file, so there is no throughput to win and no file-descriptor
// ceiling to reason about.
//
export async function hashFiles(rootDir: string, relativePaths: string[], cache: FileHashCache): Promise<Map<string, string>> {
    const hashes = new Map<string, string>();
    for (const relativePath of relativePaths) {
        hashes.set(relativePath, await hashFile(rootDir, relativePath, cache));
    }
    return hashes;
}
