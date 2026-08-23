import * as fs from "fs/promises";
import * as path from "path";
import { createHash } from "crypto";
import { getProcessTmpDir, pathExists, updateFileRawOptimistic } from "node-utils";
import { log } from "utils";

/**
 * File structure:
 *  - Version: 4 bytes (uint32)
 *  - Entry count: 4 bytes (uint32)
 *  - Entries: variable length
 *  - Checksum: 32 bytes (SHA-256) at the end
 *
 * Hash cache entry structure:
 * - Key length: 4 bytes (uint32)
 * - Key: variable length
 * - Hash: 32 bytes (SHA-256)
 * - File size: 6 bytes (uint48)
 * - Last modified: 6 bytes (uint48)
 * - Asset id: 36 bytes (ASCII, zero-padded, all zero when there is none)
 * - Keyed by source id: 1 byte (0 or 1)
 */

//
// The version of the file format. Bump it whenever the entry layout changes, and write no
// migration and no reader for the older layout.
//
// The whole cache is throwaway: everything in it can be recomputed from the files themselves, and
// the user can delete the lot with `psi hash-cache clear` without losing anything. So a cache file
// of any version but this one is discarded and rebuilt, which decodeEntries does by returning
// undefined on a version that is not equal to this one. Not "older than", not "unsupported": not
// equal.
//
const HASH_CACHE_VERSION = 2;

//
// How many bytes an asset id occupies in an entry.
//
// Fixed width, because an asset id is a UUID and a UUID is always 36 characters. Keeping it fixed
// is what lets an entry's size still be worked out from its key length alone, which every offset
// walk in this file relies on. An entry with no asset id yet stores 36 zero bytes.
//
const ASSET_ID_BYTES = 36;

//
// How many times a save retries when another process publishes a new cache file underneath it.
// Each retry re-reads the winner's file and re-applies this instance's changes onto it. This is
// set high because the cache is genuinely contended: every worker in every running instance saves
// after each file it hashes, so a writer can lose several times in a row before it lands. Losing
// all of them means the save throws and its entries wait until the next save.
//
const SAVE_RETRIES = 20;

//
// The directory holding the hash cache of one database.
//
// There is one cache per database, not one per machine, because an entry now records the id the
// file has in the database. A photo imported into two databases has two ids and one entry cannot
// hold both, so the caches are kept apart rather than making the entry carry a map of database to
// id, which would mean a variable-length field in a fixed-width binary format for the sake of a
// case that is rare.
//
// The database path is hashed rather than used directly: it can be a Windows path, a URL-ish
// "s3:bucket:/path", or anything else the storage layer accepts, none of which is safe to paste
// into a directory name. The hash is stable for a given path, which is all that is needed, and the
// commands that report on the cache print the whole directory so nobody has to decode it.
//
export function getHashCacheDir(databasePath: string): string {
    const databaseKey = createHash("sha256").update(databasePath).digest("hex").slice(0, 16);
    return path.join(getProcessTmpDir(), "photosphere", "hash-cache", databaseKey);
}

//
// A single decoded entry of the hash cache.
//
export interface IHashCacheEntry {
    // What this entry is filed under: the normalized path of a file, or the stable source id of an
    // item in a device photo library. A library item has no path until it has been copied out of
    // the library, which is the copy this cache exists to avoid, so its source id is the only
    // identity available at the moment the question is asked.
    key: string;

    // SHA-256 hash of the file's content (always 32 bytes).
    hash: Buffer;

    // Length of the file in bytes.
    length: number;

    // Last modified time of the file, in milliseconds since the epoch. For a source-keyed entry
    // this is the item's created time as the library reports it, because the temporary copy's own
    // modified time is minted by the copy and matches nothing.
    lastModified: number;

    // The id this file was given in the database this cache belongs to, once it is known to be in
    // there. Undefined means it has been hashed but is not known to be in the database, which is
    // answered by looking the hash up in the database itself.
    assetId: string | undefined;

    // True when the key is a source id rather than a file path. Recorded so the sweep that drops
    // entries for photos that have left the device can tell the two apart: a file path that is not
    // in the photo library is not a dead entry, it is a manual import.
    keyedBySourceId: boolean;
}

//
// What the cache knows about one file.
//
export interface ICachedHash {
    // SHA-256 hash of the file's content.
    hash: Buffer;

    // Length of the file in bytes.
    length: number;

    // Last modified time recorded against the entry.
    lastModified: Date;

    // The id this file has in the database, or undefined when it is not known to be in there.
    assetId: string | undefined;
}

//
// One entry as it is listed for a reader, with the hash already in hex.
//
export interface IHashCacheListing {
    // What the entry is filed under: a file path, or the source id of a photo library item.
    key: string;

    // SHA-256 hash of the file's content, lower-case hex.
    hash: string;

    // Length of the file in bytes.
    size: number;

    // Last modified time recorded against the entry.
    lastModified: Date;

    // The id this file has in the database, or undefined when it is not known to be in there.
    assetId: string | undefined;

    // True when the key is a source id rather than a file path.
    keyedBySourceId: boolean;
}

//
// The hash of one file, ready to be recorded in the cache.
//
export interface IHashToCache {
    // SHA-256 hash of the file's content (must be 32 bytes).
    hash: Buffer;

    // Length of the file in bytes.
    length: number;

    // The modified time to record against the entry.
    lastModified: Date;
}

export class HashCache {
    private buffer: Buffer | null = null;
    private initialized = false;
    private isDirty = false;
    private entryCount = 0;
    private offsetLookup: number[] = [];

    //
    // Entries this instance has added or updated since the last load or save, keyed by normalized
    // file path. They are merged onto the on-disk cache at save time so a concurrent writer's
    // entries are kept instead of being overwritten by this instance's whole snapshot.
    //
    private pendingUpserts: Map<string, IHashCacheEntry> = new Map();

    //
    // Normalized file paths this instance has removed since the last load or save. Applied to the
    // on-disk cache at save time, before the pending upserts.
    //
    private pendingRemovals: Set<string> = new Set();

    /**
     * Creates a new hash cache
     *
     * @param cacheDir The directory where the hash cache will be stored
     * @param isReadonly Whether the cache should skip saves when in readonly mode
     */
    constructor(
        private readonly cacheDir: string,
        private readonly isReadonly: boolean = false
    ) {}

    //
    // Gets the size of a hash cache entry.
    //
    private entrySize(keyLength: number): number {
        return 4 + keyLength + 32 + 6 + 6 + ASSET_ID_BYTES + 1; // keyLength + key + hash + size + lastModified + assetId + keyedBySourceId.
    }

    //
    // Reads an asset id out of an entry. All zero bytes means the entry has no asset id.
    //
    private readAssetId(source: Buffer, offset: number): string | undefined {
        if (source[offset] === 0) {
            return undefined;
        }
        return source.toString('utf8', offset, offset + ASSET_ID_BYTES).replace(/\0+$/, '');
    }

    //
    // Writes an asset id into an entry, zero-padded to the fixed width. Writing undefined clears it.
    //
    private writeAssetId(target: Buffer, offset: number, assetId: string | undefined): void {
        target.fill(0, offset, offset + ASSET_ID_BYTES);
        if (assetId === undefined) {
            return;
        }

        const assetIdBytes = Buffer.from(assetId, 'utf8');
        if (assetIdBytes.length > ASSET_ID_BYTES) {
            throw new Error(`Asset id "${assetId}" is ${assetIdBytes.length} bytes, which does not fit the ${ASSET_ID_BYTES} bytes the hash cache reserves for it.`);
        }

        assetIdBytes.copy(target, offset);
    }

    /**
     * Computes SHA-256 checksum for corruption detection
     */
    private computeChecksum(data: Buffer): Buffer {
        return createHash('sha256').update(data).digest();
    }

    //
    // Decodes the bytes of a hash cache file into its entries.
    // Returns undefined when the bytes are not a usable cache file: absent, too small to hold a
    // header and checksum, of an unsupported version, failing their checksum, or describing an
    // entry that runs past the end of the data. Callers treat that as "start fresh" and do the
    // logging, so this stays free of side effects and of any dependency on instance state.
    //
    private decodeEntries(fileBytes: Buffer | undefined): IHashCacheEntry[] | undefined {
        if (!fileBytes || fileBytes.length < 40) {
            return undefined;
        }

        const storedChecksum = fileBytes.subarray(fileBytes.length - 32);
        const dataWithoutChecksum = fileBytes.subarray(0, fileBytes.length - 32);
        if (!this.computeChecksum(dataWithoutChecksum).equals(storedChecksum)) {
            return undefined;
        }

        if (dataWithoutChecksum.readUInt32LE(0) !== HASH_CACHE_VERSION) {
            return undefined;
        }

        const entryCount = dataWithoutChecksum.readUInt32LE(4);
        const entries: IHashCacheEntry[] = [];
        let offset = 8; // Start after the version and entry count headers.

        for (let entryIndex = 0; entryIndex < entryCount; entryIndex++) {
            if (offset + 4 > dataWithoutChecksum.length) {
                return undefined;
            }

            const keyLength = dataWithoutChecksum.readUInt32LE(offset);
            if (offset + this.entrySize(keyLength) > dataWithoutChecksum.length) {
                return undefined;
            }

            offset += 4; // Skip key length.
            const key = dataWithoutChecksum.toString('utf8', offset, offset + keyLength);
            offset += keyLength; // Skip key.
            const hash = Buffer.from(dataWithoutChecksum.subarray(offset, offset + 32));
            offset += 32; // Skip hash.
            const length = dataWithoutChecksum.readUIntLE(offset, 6);
            offset += 6; // Skip size.
            const lastModified = dataWithoutChecksum.readUIntLE(offset, 6);
            offset += 6; // Skip last modified.
            const assetId = this.readAssetId(dataWithoutChecksum, offset);
            offset += ASSET_ID_BYTES; // Skip asset id.
            const keyedBySourceId = dataWithoutChecksum[offset] === 1;
            offset += 1; // Skip the source id flag.

            entries.push({ key, hash, length, lastModified, assetId, keyedBySourceId });
        }

        return entries;
    }

    //
    // Encodes entries into the bytes of a hash cache file: version and entry count headers, the
    // entries themselves, then a SHA-256 checksum of everything before it. The entries are written
    // in the order given, so callers must sort them the way the binary search expects.
    //
    private encodeEntries(entries: IHashCacheEntry[]): Buffer {
        const keyBuffers = entries.map(entry => Buffer.from(entry.key, 'utf8'));
        const totalEntryBytes = keyBuffers.reduce((total, keyBuffer) => total + this.entrySize(keyBuffer.length), 0);

        const dataBuffer = Buffer.alloc(8 + totalEntryBytes);
        dataBuffer.writeUInt32LE(HASH_CACHE_VERSION, 0);
        dataBuffer.writeUInt32LE(entries.length, 4);

        let offset = 8; // Start after the version and entry count headers.

        for (let entryIndex = 0; entryIndex < entries.length; entryIndex++) {
            const entry = entries[entryIndex];
            const keyBuffer = keyBuffers[entryIndex];
            dataBuffer.writeUInt32LE(keyBuffer.length, offset);
            offset += 4; // Skip key length.
            keyBuffer.copy(dataBuffer, offset);
            offset += keyBuffer.length; // Skip key.
            entry.hash.copy(dataBuffer, offset);
            offset += 32; // Skip hash.
            dataBuffer.writeUIntLE(entry.length, offset, 6);
            offset += 6; // Skip size.
            dataBuffer.writeUIntLE(entry.lastModified, offset, 6);
            offset += 6; // Skip last modified.
            this.writeAssetId(dataBuffer, offset, entry.assetId);
            offset += ASSET_ID_BYTES; // Skip asset id.
            dataBuffer[offset] = entry.keyedBySourceId ? 1 : 0;
            offset += 1; // Skip the source id flag.
        }

        return Buffer.concat([dataBuffer, this.computeChecksum(dataBuffer)]);
    }

    /**
     * Loads the hash cache from storage.
     * This function is 100% safe - it will never throw exceptions.
     * If there's any problem loading the cache, it logs the error and starts fresh.
     */
    async load(): Promise<boolean> {
        const cachePath = path.join(this.cacheDir, "hash-cache-x.dat");

        try {
            // Check if file exists first
            if (!await pathExists(cachePath)) {
                // File doesn't exist - create new cache
                this.initializeFreshCache();
                return false;
            }

            // File exists - read and decode it.
            const entries = this.decodeEntries(await fs.readFile(cachePath));
            if (entries === undefined) {
                log.error(`Hash cache at ${cachePath} is unusable (too small, an unsupported version, corrupted, or failing its checksum) - starting with a fresh cache`);
                this.initializeFreshCache();
                return false;
            }

            this.adoptEntries(entries);
            this.initialized = true;
            return true;
        }
        catch (error: any) {
            log.exception("Failed to load hash cache", error);
            this.initializeFreshCache();
            return false;
        }
    }

    /**
     * Initializes a fresh, empty cache
     */
    private initializeFreshCache(): void {
        this.buffer = Buffer.alloc(1024); // Start with 1KB
        this.entryCount = 0;
        this.offsetLookup = [];
        this.initialized = true;
        this.isDirty = false;
        this.pendingUpserts.clear();
        this.pendingRemovals.clear();
    }

    //
    // Adopts a sorted list of entries as this instance's state: it rebuilds the in-memory buffer
    // and lookup table from them and drops the changeset, because those entries are now exactly
    // what is on disk. The in-memory buffer holds the file layout without its trailing checksum,
    // which is what encodeEntries produces minus its last 32 bytes.
    //
    private adoptEntries(entries: IHashCacheEntry[]): void {
        const encoded = this.encodeEntries(entries);
        this.buffer = encoded.subarray(0, encoded.length - 32);
        this.createLookupTable();
        this.pendingUpserts.clear();
        this.pendingRemovals.clear();
        this.isDirty = false;
    }

    /**
     * Create the lookup table of index to offset.
     * This function is safe - it will reset the cache if corruption is detected.
     */
    private createLookupTable(): void {
        if (!this.buffer || this.buffer.length < 8) {
            this.entryCount = 0;
            this.offsetLookup = [];
            return;
        }

        try {
            // Read entry count from bytes 4-7 (after version header)
            this.entryCount = this.buffer.readUInt32LE(4);
            this.offsetLookup = [];

            let offset = 8; // Start after version and entry count headers

            for (let i = 0; i < this.entryCount; i++) {
                if (offset + 4 > this.buffer.length) {
                    log.error("Hash cache may be corrupted: insufficient data for entry");
                    this.initializeFreshCache();
                    return;
                }

                // Read path length
                const keyLength = this.buffer.readUInt32LE(offset);
                const entrySize = this.entrySize(keyLength);

                if (offset + entrySize > this.buffer.length) {
                    log.error("Hash cache may be corrupted: entry extends beyond buffer");
                    this.initializeFreshCache();
                    return;
                }

                // Store the offset in our lookup table
                this.offsetLookup.push(offset);

                // Skip to the next entry
                offset += entrySize;
            }
        }
        catch (error: any) {
            log.exception("Failed to create hash cache lookup table", error);
            this.initializeFreshCache();
        }
    }

    /**
     * Ensures the buffer has enough capacity for a new entry
     *
     * @param requiredBytes The number of bytes needed for the new entry
     */
    private ensureCapacity(requiredBytes: number): void {
        if (!this.buffer) {
            this.buffer = Buffer.alloc(Math.max(1024, requiredBytes * 2));
            return;
        }

        // Check current usage (entries start at offset 8 after version and entry count headers)
        let usedBytes = 8; // Account for version and entry count headers
        let offset = 8;

        for (let i = 0; i < this.entryCount; i++) {
            const keyLength = this.buffer.readUInt32LE(offset);
            offset += this.entrySize(keyLength);
        }

        usedBytes = offset;

        // If we don't have enough space, resize the buffer
        if (usedBytes + requiredBytes > this.buffer.length) {
            const newSize = Math.max(this.buffer.length * 2, usedBytes + requiredBytes);
            const newBuffer = Buffer.alloc(newSize);
            this.buffer.copy(newBuffer, 0, 0, usedBytes);
            this.buffer = newBuffer;
        }
    }

    /**
     * Saves the hash cache to storage.
     *
     * The save merges this instance's changes onto whatever is currently on disk rather than
     * writing its own snapshot over the top. Several Photosphere instances can share one cache
     * directory, and each one only knows about the entries it loaded plus the ones it added, so
     * overwriting would silently drop every entry another instance added in the meantime.
     * updateFileRawOptimistic does the read-modify-write under an exclusive lock, so overlapping
     * saves neither interleave their bytes nor lose each other's work. Under a load heavy enough
     * that it cannot get in at all, it gives up rather than failing the caller: the cache is only
     * an optimization, and a missing entry costs one recomputed hash.
     */
    async save(): Promise<void> {
        if (!this.initialized || !this.isDirty || !this.buffer || this.isReadonly) {
            return;
        }

        const cachePath = path.join(this.cacheDir, "hash-cache-x.dat");
        let mergedEntries: IHashCacheEntry[] = [];

        try {
            await updateFileRawOptimistic(cachePath, currentBytes => {
                const entriesByKey = new Map<string, IHashCacheEntry>();

                for (const entry of this.decodeEntries(currentBytes) || []) {
                    entriesByKey.set(entry.key, entry);
                }

                for (const removedKey of this.pendingRemovals) {
                    entriesByKey.delete(removedKey);
                }

                // This instance wins on a conflict: a freshly computed hash for a path is as valid
                // as the one already on disk.
                for (const [upsertedKey, entry] of this.pendingUpserts) {
                    entriesByKey.set(upsertedKey, entry);
                }

                // Sorted with the same ordering the binary search in findEntryOffset relies on.
                mergedEntries = Array.from(entriesByKey.values())
                    .sort((first, second) => first.key.localeCompare(second.key));

                return this.encodeEntries(mergedEntries);
            }, SAVE_RETRIES);
        }
        catch {
            // Too much contention to get in. Nothing is said about it, because nothing is wrong:
            // the changeset stays pending and stays dirty, so the next save carries these entries
            // along with whatever is added by then, and even if the process exits first the only
            // cost is recomputing those hashes next time.
            return;
        }

        // Adopt the merged result so this instance can serve entries other instances contributed.
        this.adoptEntries(mergedEntries);
    }

    /**
     * Gets the entry offset for a specific file path using binary search
     *
     * @param key The file path to search for
     * @returns The offset of the entry, or -1 if not found
     */
    private findEntryOffset(key: string): number {
        if (!this.buffer || this.entryCount === 0) {
            return -1;
        }

        // Normalize the file path for consistent comparison
        key = key.replace(/\\/g, '/');

        // Binary search through the sorted entries
        let low = 0;
        let high = this.entryCount - 1;

        while (low <= high) {
            const mid = Math.floor((low + high) / 2);
            const entryOffset = this.getEntryOffsetByIndex(mid);
            if (entryOffset < 0) {
                return -1; // Something went wrong
            }

            const keyLength = this.buffer.readUInt32LE(entryOffset);
            const entryKey = this.buffer.toString('utf8', entryOffset + 4, entryOffset + 4 + keyLength);

            const comparison = key.localeCompare(entryKey);

            if (comparison === 0) {
                return entryOffset; // Found
            }
            else if (comparison < 0) {
                high = mid - 1; // Search in the lower half
            }
            else {
                low = mid + 1; // Search in the upper half
            }
        }

        return -(low + 1); // Return insertion point as a negative number
    }

    /**
     * Gets the offset of an entry by its index
     *
     * @param index The index of the entry (0-based)
     * @returns The offset of the entry, or -1 if out of bounds
     */
    private getEntryOffsetByIndex(index: number): number {
        if (!this.buffer || index < 0 || index >= this.entryCount) {
            return -1;
        }

        // The lookup table should always be fully populated
        if (index >= this.offsetLookup.length) {
            throw new Error(`Index ${index} is out of bounds for offset lookup table of length ${this.offsetLookup.length}`);
        }

        return this.offsetLookup[index];
    }

    /**
     * Retrieves a hash from the cache
     *
     * @param key The file path, or the source id of a photo library item
     * @returns What the cache knows about it, or undefined when it holds nothing under that key
     */
    getHash(key: string): ICachedHash | undefined {
        if (!this.initialized || !this.buffer) {
            return undefined;
        }

        //
        // Remove leading slash.
        //
        if (key.startsWith('/')) {
            key = key.slice(1);
        }

        const entryOffset = this.findEntryOffset(key);

        if (entryOffset < 0) {
            return undefined; // Not found
        }

        let offset = entryOffset;
        const keyLength = this.buffer.readUInt32LE(offset);
        offset += 4 + keyLength; // Skip key.
        const hash = Buffer.from(this.buffer.slice(offset, offset + 32));
        offset += 32; // Skip hash.
        const length = this.buffer.readUIntLE(offset, 6);
        offset += 6; // Skip size.
        const lastModified = new Date(this.buffer.readUIntLE(offset, 6));
        offset += 6; // Skip last modified.
        const assetId = this.readAssetId(this.buffer, offset);

        return { hash, length, lastModified, assetId };
    }

    //
    // Adds or updates the hash of a file, filed under its path.
    //
    addHash(key: string, hashedFile: IHashToCache): void {
        this.upsertHash(key, hashedFile, false);
    }

    //
    // Adds or updates the hash of an item in a device photo library, filed under the stable source
    // id the library gives it rather than under a path.
    //
    // A library item has no path until it has been copied into the app's sandbox, and that copy is
    // the expensive thing this cache exists to avoid, so a path-keyed entry could only ever be
    // written after paying the cost it was supposed to save. The source id is the identity that
    // exists before the copy, so it is what the entry is filed under.
    //
    addSourceHash(sourceId: string, hashedFile: IHashToCache): void {
        this.upsertHash(sourceId, hashedFile, true);
    }

    /**
     * Adds or updates a hash in the cache
     *
     * @param key The file path, or the source id of a photo library item
     * @param hashedFile The hash, length and modified time to record
     * @param keyedBySourceId Whether the key is a source id rather than a file path
     */
    private upsertHash(key: string, hashedFile: IHashToCache, keyedBySourceId: boolean): void {
        if (!this.initialized) {
            throw new Error("Hash cache not initialized");
        }

        //
        // Remove leading slash.
        //
        if (key.startsWith('/')) {
            key = key.slice(1);
        }

        const { hash, length, lastModified } = hashedFile;

        if (hash.length !== 32) {
            throw new Error(`Invalid hash length: ${hash.length}. Expected 32 bytes.`);
        }

        // Normalize the file path for consistent comparison
        key = key.replace(/\\/g, '/');

        const entryOffset = this.findEntryOffset(key);
        if (entryOffset >= 0) {
            // Update existing entry
            let offset = entryOffset;
            const keyLength = this.buffer!.readUInt32LE(offset);
            offset += 4 + keyLength; // Skip key.
            hash.copy(this.buffer!, offset, 0, 32);
            offset += 32; // Skip hash.
            this.buffer!.writeUIntLE(length, offset, 6);
            offset += 6; // Skip size.
            this.buffer!.writeUIntLE(lastModified.getTime(), offset, 6);
            offset += 6; // Skip last modified.
            // The asset id is cleared rather than kept: this call says the file has just been
            // hashed, so whatever id was recorded belongs to the content that was there before.
            this.writeAssetId(this.buffer!, offset, undefined);
            offset += ASSET_ID_BYTES; // Skip asset id.
            this.buffer![offset] = keyedBySourceId ? 1 : 0;
            offset += 1; // Skip the source id flag.
        }
        else {
            // Add new entry - need to find insertion point and shift entries
            const insertionIndex = -(entryOffset + 1);
            const keyBuffer = Buffer.from(key, 'utf8');
            const keyLength = keyBuffer.length;
            const entrySize = this.entrySize(keyLength);

            // Ensure we have enough space
            this.ensureCapacity(entrySize);

            // Get offset where the new entry should be inserted
            let newEntryOffset = 8; // Entries start at offset 8 after version and entry count headers
            if (insertionIndex > 0) {
                newEntryOffset = this.getEntryOffsetByIndex(insertionIndex - 1);
                if (newEntryOffset >= 0) {
                    const prevKeyLength = this.buffer!.readUInt32LE(newEntryOffset);
                    newEntryOffset += this.entrySize(prevKeyLength);
                }
            }

            // Shift all entries after the insertion point
            if (insertionIndex < this.entryCount && newEntryOffset >= 0) {
                const endOffset = this.getEntryOffsetByIndex(this.entryCount - 1);
                if (endOffset >= 0) {
                    const lastKeyLength = this.buffer!.readUInt32LE(endOffset);
                    const dataToShift = endOffset + this.entrySize(lastKeyLength) - newEntryOffset;
                    this.buffer!.copy(
                        this.buffer!,
                        newEntryOffset + entrySize,
                        newEntryOffset,
                        newEntryOffset + dataToShift
                    );
                }
            }

            // Write the new entry
            let offset = newEntryOffset;
            this.buffer!.writeUInt32LE(keyLength, offset);
            offset += 4; // Skip key length.
            keyBuffer.copy(this.buffer!, offset);
            offset += keyLength; // Skip key.
            hash.copy(this.buffer!, offset);
            offset += 32; // Skip hash.
            this.buffer!.writeUIntLE(length, offset, 6);
            offset += 6; // Skip size.
            this.buffer!.writeUIntLE(lastModified.getTime(), offset, 6);
            offset += 6; // Skip last modified.
            this.writeAssetId(this.buffer!, offset, undefined);
            offset += ASSET_ID_BYTES; // Skip asset id.
            this.buffer![offset] = keyedBySourceId ? 1 : 0;
            offset += 1; // Skip the source id flag.

            this.entryCount++;

            // Update the offset lookup table
            // Only need to adjust offsets after the insertion point
            const newOffsetLookup = this.offsetLookup.slice(0, insertionIndex);
            newOffsetLookup.push(newEntryOffset);

            // Shift all subsequent offsets by entrySize
            for (let i = insertionIndex; i < this.offsetLookup.length; i++) {
                newOffsetLookup.push(this.offsetLookup[i] + entrySize);
            }

            this.offsetLookup = newOffsetLookup;
        }

        // Record the change so the next save merges it onto the on-disk cache instead of
        // overwriting entries other instances added. The hash is copied because the caller keeps
        // ownership of the buffer it passed in.
        this.pendingUpserts.set(key, { key, hash: Buffer.from(hash), length, lastModified: lastModified.getTime(), assetId: undefined, keyedBySourceId });
        this.pendingRemovals.delete(key);

        this.isDirty = true;
    }

    //
    // Records the id an entry's file has in the database, so the next run knows the file is in
    // there without asking the database at all.
    //
    // Returns false when the cache holds nothing under that key, which is not an error: the entry
    // may have been swept, or written by another process that has not saved yet, and the caller
    // simply pays for one database lookup next time.
    //
    setAssetId(key: string, assetId: string): boolean {
        if (!this.initialized || !this.buffer) {
            return false;
        }

        //
        // Remove leading slash.
        //
        if (key.startsWith('/')) {
            key = key.slice(1);
        }

        key = key.replace(/\\/g, '/');

        const entryOffset = this.findEntryOffset(key);
        if (entryOffset < 0) {
            return false;
        }

        let offset = entryOffset;
        const keyLength = this.buffer.readUInt32LE(offset);
        offset += 4 + keyLength; // Skip key.
        const hash = Buffer.from(this.buffer.subarray(offset, offset + 32));
        offset += 32; // Skip hash.
        const length = this.buffer.readUIntLE(offset, 6);
        offset += 6; // Skip size.
        const lastModified = this.buffer.readUIntLE(offset, 6);
        offset += 6; // Skip last modified.
        this.writeAssetId(this.buffer, offset, assetId);
        offset += ASSET_ID_BYTES; // Skip asset id.
        const keyedBySourceId = this.buffer[offset] === 1;

        // The whole entry goes into the changeset, because the save merges whole entries rather
        // than fields.
        this.pendingUpserts.set(key, { key, hash, length, lastModified, assetId, keyedBySourceId });
        this.pendingRemovals.delete(key);

        this.isDirty = true;
        return true;
    }

    //
    // Drops every source-keyed entry whose source id is not in the given set, and returns how many
    // went. This is how the cache stops growing forever on a device where photos come and go.
    //
    // Only source-keyed entries are considered. A file path that is not in the photo library is not
    // a dead entry, it is a manual import, and sweeping those would throw away the desktop's whole
    // cache the first time automatic import walked a folder.
    //
    // The caller has to have walked the whole listing before calling this: a partial listing would
    // read as "everything else is gone" and delete the lot.
    //
    removeSourceEntriesNotIn(liveSourceIds: Set<string>): number {
        const deadKeys = this.getAllEntries()
            .filter(entry => entry.keyedBySourceId && !liveSourceIds.has(entry.key))
            .map(entry => entry.key);

        for (const deadKey of deadKeys) {
            this.removeHash(deadKey);
        }

        return deadKeys.length;
    }

    /**
     * Removes a hash from the cache
     *
     * @param key The path of the file
     * @returns true if the hash was removed, false if it wasn't found
     */
    removeHash(key: string): boolean {
        if (!this.initialized || !this.buffer) {
            return false;
        }

        //
        // Remove leading slash.
        //
        if (key.startsWith('/')) {
            key = key.slice(1);
        }

        const entryOffset = this.findEntryOffset(key);
        if (entryOffset < 0) {
            return false; // Not found
        }

        const keyLength = this.buffer.readUInt32LE(entryOffset);
        const entrySize = this.entrySize(keyLength);

        // Shift all entries after this one
        const nextEntryOffset = entryOffset + entrySize;
        if (nextEntryOffset < this.buffer.length) {
            this.buffer.copy(
                this.buffer,
                entryOffset,
                nextEntryOffset,
                this.buffer.length
            );
        }

        this.entryCount--;
        this.isDirty = true;

        // Record the removal so the next save applies it to the on-disk cache. The key uses the
        // same normalization findEntryOffset applies, so it matches the entry that was removed.
        const normalizedKey = key.replace(/\\/g, '/');
        this.pendingRemovals.add(normalizedKey);
        this.pendingUpserts.delete(normalizedKey);

        // Find the index of the entry that was removed
        const removedIndex = this.offsetLookup.findIndex(offset => offset === entryOffset);
        if (removedIndex !== -1) {
            // Remove the entry from the lookup table
            const newOffsetLookup = this.offsetLookup.slice(0, removedIndex);

            // Shift all subsequent offsets by -entrySize
            for (let i = removedIndex + 1; i < this.offsetLookup.length; i++) {
                newOffsetLookup.push(this.offsetLookup[i] - entrySize);
            }

            this.offsetLookup = newOffsetLookup;
        }
        else {
            // This should never happen if the code is correct
            throw new Error("Removed entry not found in offset lookup table");
        }

        return true;
    }

    /**
     * Gets the number of entries in the cache
     */
    getEntryCount(): number {
        return this.entryCount;
    }

    /**
     * Gets all entries from the cache
     * @returns An array of cache entries
     */
    getAllEntries(): IHashCacheListing[] {
        const entries: IHashCacheListing[] = [];

        if (!this.buffer || this.entryCount === 0) {
            return entries;
        }

        for (let i = 0; i < this.entryCount; i++) {
            const offset = this.getEntryOffsetByIndex(i);
            if (offset < 0) continue;
            
            let currentOffset = offset;
            const keyLength = this.buffer.readUInt32LE(currentOffset);
            currentOffset += 4;
            
            const key = this.buffer.toString('utf8', currentOffset, currentOffset + keyLength);
            currentOffset += keyLength;
            
            const hash = this.buffer.slice(currentOffset, currentOffset + 32).toString('hex');
            currentOffset += 32;
            
            const size = this.buffer.readUIntLE(currentOffset, 6);
            currentOffset += 6;
            
            const lastModified = new Date(this.buffer.readUIntLE(currentOffset, 6));
            currentOffset += 6;

            const assetId = this.readAssetId(this.buffer, currentOffset);
            currentOffset += ASSET_ID_BYTES;

            const keyedBySourceId = this.buffer[currentOffset] === 1;

            entries.push({ key, hash, size, lastModified, assetId, keyedBySourceId });
        }
        
        return entries;
    }
}

