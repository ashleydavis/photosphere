import { createReadStream, statSync } from "fs";
import { HashCache, computeHash, getHashCacheDir } from "node-api";
import { exit } from "node-utils";
import { log } from "utils";

//
// Internal tools for driving a database's hash cache directly.
//
// These are for development and for the concurrency smoke test, not for end users, so the commands
// that call them are registered as hidden. They print plain, parseable output rather than anything
// decorated, because scripts read it.
//

//
// The options every one of these tools takes.
//
export interface IHashCacheToolOptions {
    // The database whose cache to act on. Required, because there is one cache per database.
    //
    // Taken as given rather than resolved through loadDatabase the way the user-facing commands do:
    // these tools act on the cache alone and are pointed at a path by a test script, so there is
    // nothing to resolve and no database that has to exist.
    db: string;
}

//
// Loads a database's hash cache, ready to be read or written.
//
async function openHashCache(options: IHashCacheToolOptions): Promise<HashCache> {
    const hashCache = new HashCache(getHashCacheDir(options.db));
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
// Command to hash a file and record it in the hash cache under its own path.
//
export async function hashCacheAddCommand(filePath: string, options: IHashCacheToolOptions): Promise<void> {
    const hash = await computeHash(createReadStream(filePath));
    const fileStat = statSync(filePath);

    const hashCache = await openHashCache(options);
    hashCache.addHash(filePath, { hash, length: fileStat.size, lastModified: fileStat.mtime });
    await hashCache.save();

    log.info(hash.toString('hex'));
    await exit(0);
}

//
// Command to record a hash in the hash cache against an arbitrary path, without needing the
// file to exist. This is what the concurrency smoke test uses to generate cache entries cheaply.
//
export async function hashCacheSetCommand(entryKey: string, hashHex: string, length: string, options: IHashCacheToolOptions): Promise<void> {
    const hashCache = await openHashCache(options);
    hashCache.addHash(entryKey, {
        hash: Buffer.from(hashHex, 'hex'),
        length: parseInt(length, 10),
        lastModified: new Date(0),
    });
    await hashCache.save();

    await exit(0);
}

//
// Command to record a hash in the hash cache against the source id of a photo library item, which
// is how automatic import files what it has hashed.
//
export async function hashCacheSetSourceCommand(sourceId: string, hashHex: string, length: string, options: IHashCacheToolOptions): Promise<void> {
    const hashCache = await openHashCache(options);
    hashCache.addSourceHash(sourceId, {
        hash: Buffer.from(hashHex, 'hex'),
        length: parseInt(length, 10),
        lastModified: new Date(0),
    });
    await hashCache.save();

    await exit(0);
}

//
// Command to read one entry back out of the hash cache.
// Prints the hash as hex, or nothing when the key is not cached, and exits 1 so a script can tell
// a miss from a hit without parsing the output.
//
export async function hashCacheGetCommand(entryKey: string, options: IHashCacheToolOptions): Promise<void> {
    const hashCache = await openHashCache(options);
    const cacheEntry = hashCache.getHash(entryKey);
    if (!cacheEntry) {
        await exit(1);
        return;
    }

    log.info(cacheEntry.hash.toString('hex'));
    await exit(0);
}

//
// Command to print the asset id recorded against one entry.
// Exits 1 when the entry is missing or has no asset id, so a script can tell the two states apart
// from a recorded id without parsing the output.
//
export async function hashCacheGetAssetIdCommand(entryKey: string, options: IHashCacheToolOptions): Promise<void> {
    const hashCache = await openHashCache(options);
    const cacheEntry = hashCache.getHash(entryKey);
    if (!cacheEntry || cacheEntry.assetId === undefined) {
        await exit(1);
        return;
    }

    log.info(cacheEntry.assetId);
    await exit(0);
}

//
// Command to drop one entry from the hash cache.
// Exits 1 when there was nothing to remove.
//
export async function hashCacheRemoveCommand(entryKey: string, options: IHashCacheToolOptions): Promise<void> {
    const hashCache = await openHashCache(options);
    const removed = hashCache.removeHash(entryKey);
    if (removed) {
        await hashCache.save();
    }

    await exit(removed ? 0 : 1);
}

//
// Command to print the key of every entry in the hash cache, one per line, so a script can
// check exactly which entries survived.
//
export async function hashCacheListCommand(options: IHashCacheToolOptions): Promise<void> {
    const hashCache = await openHashCache(options);
    for (const cacheEntry of hashCache.getAllEntries()) {
        log.info(cacheEntry.key);
    }

    await exit(0);
}

//
// Command to print how many entries the hash cache holds.
//
export async function hashCacheCountCommand(options: IHashCacheToolOptions): Promise<void> {
    const hashCache = await openHashCache(options);
    log.info(hashCache.getEntryCount().toString());
    await exit(0);
}

//
// Command to print the directory holding a database's hash cache, so a script can look at the file
// itself without having to work out how the path is derived.
//
export async function hashCacheDirCommand(options: IHashCacheToolOptions): Promise<void> {
    log.info(getHashCacheDir(options.db));
    await exit(0);
}
