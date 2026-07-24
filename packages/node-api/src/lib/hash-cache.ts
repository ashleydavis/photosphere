import * as fs from "fs/promises";
import * as path from "path";
import { createHash } from "crypto";
import { pathExists, updateFileRawOptimistic } from "node-utils";
import { log } from "utils";

/**
 * File structure:
 *  - Version: 4 bytes (uint32)
 *  - Entry count: 4 bytes (uint32)
 *  - Entries: variable length
 *  - Checksum: 32 bytes (SHA-256) at the end
 *
 * Hash cache entry structure:
 * - Path length: 4 bytes (uint32)
 * - File path: variable length
 * - Hash: 32 bytes (SHA-256)
 * - File size: 6 bytes (uint48)
 * - Last modified: 6 bytes (uint48)
 */

const HASH_CACHE_VERSION = 1;

//
// How many times a save retries when another process publishes a new cache file underneath it.
// Each retry re-reads the winner's file and re-applies this instance's changes onto it. This is
// set high because the cache is genuinely contended: every worker in every running instance saves
// after each file it hashes, so a writer can lose several times in a row before it lands. Losing
// all of them means the save throws and its entries wait until the next save.
//
const SAVE_RETRIES = 20;

//
// A single decoded entry of the hash cache.
//
export interface IHashCacheEntry {
    // Normalized path of the file this entry describes.
    filePath: string;

    // SHA-256 hash of the file's content (always 32 bytes).
    hash: Buffer;

    // Length of the file in bytes.
    length: number;

    // Last modified time of the file, in milliseconds since the epoch.
    lastModified: number;
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
    private entrySize(pathLength: number): number {
        return 4 + pathLength + 32 + 6 + 6; // pathLength + path + hash + size + lastModified.
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

            const pathLength = dataWithoutChecksum.readUInt32LE(offset);
            if (offset + this.entrySize(pathLength) > dataWithoutChecksum.length) {
                return undefined;
            }

            offset += 4; // Skip path length.
            const filePath = dataWithoutChecksum.toString('utf8', offset, offset + pathLength);
            offset += pathLength; // Skip path.
            const hash = Buffer.from(dataWithoutChecksum.subarray(offset, offset + 32));
            offset += 32; // Skip hash.
            const length = dataWithoutChecksum.readUIntLE(offset, 6);
            offset += 6; // Skip size.
            const lastModified = dataWithoutChecksum.readUIntLE(offset, 6);
            offset += 6; // Skip last modified.

            entries.push({ filePath, hash, length, lastModified });
        }

        return entries;
    }

    //
    // Encodes entries into the bytes of a hash cache file: version and entry count headers, the
    // entries themselves, then a SHA-256 checksum of everything before it. The entries are written
    // in the order given, so callers must sort them the way the binary search expects.
    //
    private encodeEntries(entries: IHashCacheEntry[]): Buffer {
        const pathBuffers = entries.map(entry => Buffer.from(entry.filePath, 'utf8'));
        const totalEntryBytes = pathBuffers.reduce((total, pathBuffer) => total + this.entrySize(pathBuffer.length), 0);

        const dataBuffer = Buffer.alloc(8 + totalEntryBytes);
        dataBuffer.writeUInt32LE(HASH_CACHE_VERSION, 0);
        dataBuffer.writeUInt32LE(entries.length, 4);

        let offset = 8; // Start after the version and entry count headers.

        for (let entryIndex = 0; entryIndex < entries.length; entryIndex++) {
            const entry = entries[entryIndex];
            const pathBuffer = pathBuffers[entryIndex];
            dataBuffer.writeUInt32LE(pathBuffer.length, offset);
            offset += 4; // Skip path length.
            pathBuffer.copy(dataBuffer, offset);
            offset += pathBuffer.length; // Skip path.
            entry.hash.copy(dataBuffer, offset);
            offset += 32; // Skip hash.
            dataBuffer.writeUIntLE(entry.length, offset, 6);
            offset += 6; // Skip size.
            dataBuffer.writeUIntLE(entry.lastModified, offset, 6);
            offset += 6; // Skip last modified.
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
                const pathLength = this.buffer.readUInt32LE(offset);
                const entrySize = this.entrySize(pathLength);

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
            const pathLength = this.buffer.readUInt32LE(offset);
            offset += this.entrySize(pathLength);
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
                const entriesByPath = new Map<string, IHashCacheEntry>();

                for (const entry of this.decodeEntries(currentBytes) || []) {
                    entriesByPath.set(entry.filePath, entry);
                }

                for (const removedPath of this.pendingRemovals) {
                    entriesByPath.delete(removedPath);
                }

                // This instance wins on a conflict: a freshly computed hash for a path is as valid
                // as the one already on disk.
                for (const [upsertedPath, entry] of this.pendingUpserts) {
                    entriesByPath.set(upsertedPath, entry);
                }

                // Sorted with the same ordering the binary search in findEntryOffset relies on.
                mergedEntries = Array.from(entriesByPath.values())
                    .sort((first, second) => first.filePath.localeCompare(second.filePath));

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
     * @param filePath The file path to search for
     * @returns The offset of the entry, or -1 if not found
     */
    private findEntryOffset(filePath: string): number {
        if (!this.buffer || this.entryCount === 0) {
            return -1;
        }

        // Normalize the file path for consistent comparison
        filePath = filePath.replace(/\\/g, '/');

        // Binary search through the sorted entries
        let low = 0;
        let high = this.entryCount - 1;

        while (low <= high) {
            const mid = Math.floor((low + high) / 2);
            const entryOffset = this.getEntryOffsetByIndex(mid);
            if (entryOffset < 0) {
                return -1; // Something went wrong
            }

            const pathLength = this.buffer.readUInt32LE(entryOffset);
            const entryPath = this.buffer.toString('utf8', entryOffset + 4, entryOffset + 4 + pathLength);

            const comparison = filePath.localeCompare(entryPath);

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
     * Retrieves a hash for a file from the cache
     *
     * @param filePath The path of the file
     * @returns The hash and size if found, undefined otherwise
     */
    getHash(filePath: string): { hash: Buffer, length: number, lastModified: Date } | undefined {
        if (!this.initialized || !this.buffer) {
            return undefined;
        }

        //
        // Remove leading slash.
        //
        if (filePath.startsWith('/')) {
            filePath = filePath.slice(1);
        }

        const entryOffset = this.findEntryOffset(filePath);

        if (entryOffset < 0) {
            return undefined; // Not found
        }

        let offset = entryOffset;
        const pathLength = this.buffer.readUInt32LE(offset);
        offset += 4 + pathLength; // Skip path.
        const hash = Buffer.from(this.buffer.slice(offset, offset + 32));
        offset += 32; // Skip hash.
        const length = this.buffer.readUIntLE(offset, 6);
        offset += 6; // Skip size.
        const lastModified = new Date(this.buffer.readUIntLE(offset, 6));

        return { hash, length, lastModified };
    }

    /**
     * Adds or updates a hash in the cache
     *
     * @param filePath The path of the file
     * @param hash The hash of the file (32 bytes)
     * @param size The size of the file in bytes
     */
    addHash(filePath: string, hashedFile: { hash: Buffer, length: number, lastModified: Date }): void {
        if (!this.initialized) {
            throw new Error("Hash cache not initialized");
        }

        //
        // Remove leading slash.
        //
        if (filePath.startsWith('/')) {
            filePath = filePath.slice(1);
        }

        const { hash, length, lastModified } = hashedFile;

        if (hash.length !== 32) {
            throw new Error(`Invalid hash length: ${hash.length}. Expected 32 bytes.`);
        }

        // Normalize the file path for consistent comparison
        filePath = filePath.replace(/\\/g, '/');

        const entryOffset = this.findEntryOffset(filePath);
        if (entryOffset >= 0) {
            // Update existing entry
            let offset = entryOffset;
            const pathLength = this.buffer!.readUInt32LE(offset);
            offset += 4 + pathLength; // Skip path.
            hash.copy(this.buffer!, offset, 0, 32);
            offset += 32; // Skip hash.
            this.buffer!.writeUIntLE(length, offset, 6);
            offset += 6; // Skip size.
            this.buffer!.writeUIntLE(lastModified.getTime(), offset, 6);
            offset += 6; // Skip last modified.
        }
        else {
            // Add new entry - need to find insertion point and shift entries
            const insertionIndex = -(entryOffset + 1);
            const pathBuffer = Buffer.from(filePath, 'utf8');
            const pathLength = pathBuffer.length;
            const entrySize = this.entrySize(pathLength);

            // Ensure we have enough space
            this.ensureCapacity(entrySize);

            // Get offset where the new entry should be inserted
            let newEntryOffset = 8; // Entries start at offset 8 after version and entry count headers
            if (insertionIndex > 0) {
                newEntryOffset = this.getEntryOffsetByIndex(insertionIndex - 1);
                if (newEntryOffset >= 0) {
                    const prevPathLength = this.buffer!.readUInt32LE(newEntryOffset);
                    newEntryOffset += this.entrySize(prevPathLength);
                }
            }

            // Shift all entries after the insertion point
            if (insertionIndex < this.entryCount && newEntryOffset >= 0) {
                const endOffset = this.getEntryOffsetByIndex(this.entryCount - 1);
                if (endOffset >= 0) {
                    const lastPathLength = this.buffer!.readUInt32LE(endOffset);
                    const dataToShift = endOffset + this.entrySize(lastPathLength) - newEntryOffset;
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
            this.buffer!.writeUInt32LE(pathLength, offset);
            offset += 4; // Skip path length.
            pathBuffer.copy(this.buffer!, offset);
            offset += pathLength; // Skip path.
            hash.copy(this.buffer!, offset);
            offset += 32; // Skip hash.
            this.buffer!.writeUIntLE(length, offset, 6);
            offset += 6; // Skip size.
            this.buffer!.writeUIntLE(lastModified.getTime(), offset, 6);
            offset += 6; // Skip last modified.

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
        this.pendingUpserts.set(filePath, { filePath, hash: Buffer.from(hash), length, lastModified: lastModified.getTime() });
        this.pendingRemovals.delete(filePath);

        this.isDirty = true;
    }

    /**
     * Removes a hash from the cache
     *
     * @param filePath The path of the file
     * @returns true if the hash was removed, false if it wasn't found
     */
    removeHash(filePath: string): boolean {
        if (!this.initialized || !this.buffer) {
            return false;
        }

        //
        // Remove leading slash.
        //
        if (filePath.startsWith('/')) {
            filePath = filePath.slice(1);
        }

        const entryOffset = this.findEntryOffset(filePath);
        if (entryOffset < 0) {
            return false; // Not found
        }

        const pathLength = this.buffer.readUInt32LE(entryOffset);
        const entrySize = this.entrySize(pathLength);

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
        const normalizedPath = filePath.replace(/\\/g, '/');
        this.pendingRemovals.add(normalizedPath);
        this.pendingUpserts.delete(normalizedPath);

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
    getAllEntries(): Array<{ filePath: string, hash: string, size: number, lastModified: Date }> {
        const entries: Array<{ filePath: string, hash: string, size: number, lastModified: Date }> = [];
        
        if (!this.buffer || this.entryCount === 0) {
            return entries;
        }

        for (let i = 0; i < this.entryCount; i++) {
            const offset = this.getEntryOffsetByIndex(i);
            if (offset < 0) continue;
            
            let currentOffset = offset;
            const pathLength = this.buffer.readUInt32LE(currentOffset);
            currentOffset += 4;
            
            const filePath = this.buffer.toString('utf8', currentOffset, currentOffset + pathLength);
            currentOffset += pathLength;
            
            const hash = this.buffer.slice(currentOffset, currentOffset + 32).toString('hex');
            currentOffset += 32;
            
            const size = this.buffer.readUIntLE(currentOffset, 6);
            currentOffset += 6;
            
            const lastModified = new Date(this.buffer.readUIntLE(currentOffset, 6));
            
            entries.push({ filePath, hash, size, lastModified });
        }
        
        return entries;
    }
}

