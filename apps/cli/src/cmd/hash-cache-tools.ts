import { createReadStream, statSync } from "fs";
import path from "path";
import { HashCache, computeHash } from "node-api";
import { exit, getProcessTmpDir } from "node-utils";
import { log } from "utils";

//
// Internal tools for driving the local hash cache directly.
//
// These are for development and for the concurrency smoke test, not for end users, so the commands
// that call them are registered as hidden. They print plain, parseable output rather than anything
// decorated, because scripts read it.
//

//
// Gets the directory holding the local hash cache. It is derived exactly like every other user of
// the local cache, so these tools act on the same cache the real commands do.
//
function getLocalHashCacheDir(): string {
    return path.join(getProcessTmpDir(), "photosphere");
}

//
// Loads the local hash cache, ready to be read or written.
//
async function openLocalHashCache(): Promise<HashCache> {
    const hashCache = new HashCache(getLocalHashCacheDir());
    await hashCache.load();
    return hashCache;
}

//
// Command to compute the SHA-256 hash of a file, without touching the cache.
// Prints the hash as hex.
//
export async function hashFileCommand(filePath: string): Promise<void> {
    const hash = await computeHash(createReadStream(filePath));
    log.info(hash.toString('hex'));
    await exit(0);
}

//
// Command to hash a file and record it in the local hash cache under its own path.
//
export async function hashCacheAddCommand(filePath: string): Promise<void> {
    const hash = await computeHash(createReadStream(filePath));
    const fileStat = statSync(filePath);

    const hashCache = await openLocalHashCache();
    hashCache.addHash(filePath, { hash, length: fileStat.size, lastModified: fileStat.mtime });
    await hashCache.save();

    log.info(hash.toString('hex'));
    await exit(0);
}

//
// Command to record a hash in the local hash cache against an arbitrary path, without needing the
// file to exist. This is what the concurrency smoke test uses to generate cache entries cheaply.
//
export async function hashCacheSetCommand(entryPath: string, hashHex: string, length: string): Promise<void> {
    const hashCache = await openLocalHashCache();
    hashCache.addHash(entryPath, {
        hash: Buffer.from(hashHex, 'hex'),
        length: parseInt(length, 10),
        lastModified: new Date(0),
    });
    await hashCache.save();

    await exit(0);
}

//
// Command to read one entry back out of the local hash cache.
// Prints the hash as hex, or nothing when the path is not cached, and exits 1 so a script can tell
// a miss from a hit without parsing the output.
//
export async function hashCacheGetCommand(entryPath: string): Promise<void> {
    const hashCache = await openLocalHashCache();
    const cacheEntry = hashCache.getHash(entryPath);
    if (!cacheEntry) {
        await exit(1);
        return;
    }

    log.info(cacheEntry.hash.toString('hex'));
    await exit(0);
}

//
// Command to drop one entry from the local hash cache.
// Exits 1 when there was nothing to remove.
//
export async function hashCacheRemoveCommand(entryPath: string): Promise<void> {
    const hashCache = await openLocalHashCache();
    const removed = hashCache.removeHash(entryPath);
    if (removed) {
        await hashCache.save();
    }

    await exit(removed ? 0 : 1);
}

//
// Command to print the paths of every entry in the local hash cache, one per line, so a script can
// check exactly which entries survived.
//
export async function hashCacheListCommand(): Promise<void> {
    const hashCache = await openLocalHashCache();
    for (const cacheEntry of hashCache.getAllEntries()) {
        log.info(cacheEntry.filePath);
    }

    await exit(0);
}

//
// Command to print how many entries the local hash cache holds.
//
export async function hashCacheCountCommand(): Promise<void> {
    const hashCache = await openLocalHashCache();
    log.info(hashCache.getEntryCount().toString());
    await exit(0);
}
