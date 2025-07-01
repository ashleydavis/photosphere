import { IStorage, pathJoin } from "storage";

/**
 * Starts with:
 *  - Version: 4 bytes
 *  - Entry count: 4 bytes
 *
 * Hash cache entry structure:
 * - Path length: 4 bytes (uint32)
 * - File path: variable length
 * - Hash: 32 bytes (SHA-256)
 * - File size: 6 bytes (uint48)
 * - Last modified: 6 bytes (uint48)
 */

export class HashCache {
    private buffer: Buffer | null = null;
    private initialized = false;
    private isDirty = false;
    private entryCount = 0;
    private offsetLookup: number[] = [];

    /**
     * Creates a new hash cache
     *
     * @param storage The storage implementation for persistence
     * @param cacheDir The directory where the hash cache will be stored
     */
    constructor(
        private readonly storage: IStorage,
        private readonly cacheDir: string
    ) {}

    //
    // Gets the size of a hash cache entry.
    //
    private entrySize(pathLength: number): number {
        return 4 + pathLength + 32 + 6 + 6; // pathLength + path + hash + size + lastModified.
    }

    /**
     * Loads the hash cache from storage.
     */
    async load(): Promise<boolean> {
        const cachePath = pathJoin(this.cacheDir, "hash-cache-x.dat");
        const cacheData = await this.storage.read(cachePath);
        if (cacheData) {
            this.buffer = cacheData;
            this.createLookupTable();
            this.initialized = true;
            return true;
        }

        // Create a new empty cache if it doesn't exist
        this.buffer = Buffer.alloc(1024); // Start with 1KB
        this.entryCount = 0;
        this.initialized = true;

        return false;
    }

    /**
     * Create the lookup table of index to offset.
     */
    private createLookupTable(): void {
        if (!this.buffer || this.buffer.length === 0) {
            this.entryCount = 0;
            this.offsetLookup = [];
            return;
        }

        let offset = 0;
        let count = 0;
        this.offsetLookup = [];

        //todo: be good to just load entryCount from the buffer.

        while (offset < this.buffer.length) {
            // Check if we've reached the end of the entries
            if (this.buffer[offset] === 0 && this.buffer[offset + 1] === 0) { //todo: needed?
                break;
            }

            // Read path length
            const pathLength = this.buffer.readUInt32LE(offset);
            if (pathLength === 0) {  //todo: needed?
                break; // End of entries
            }

            // Store the offset in our lookup table
            this.offsetLookup.push(offset);

            // Skip to the next entry
            offset += this.entrySize(pathLength);
            count++;

            // Sanity check to prevent infinite loops
            if (offset > this.buffer.length) {
                console.warn("Hash cache may be corrupted");
                break;
            }
        }

        this.entryCount = count;
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

        // Check current usage
        let usedBytes = 0;
        let offset = 0;

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
     * Saves the hash cache to storage
     */
    async save(): Promise<void> {
        if (!this.initialized || !this.isDirty || !this.buffer) {
            return;
        }

        const cachePath = pathJoin(this.cacheDir, "hash-cache-x.dat");

        // Calculate actual used size
        let offset = 0;

        for (let i = 0; i < this.entryCount; i++) {
            const pathLength = this.buffer.readUInt32LE(offset);
            offset += this.entrySize(pathLength);
        }

        // Write only the used portion of the buffer
        const usedBuffer = this.buffer.slice(0, offset);
        await this.storage.write(cachePath, undefined, usedBuffer);
        this.isDirty = false;
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
            let newEntryOffset = 0;
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