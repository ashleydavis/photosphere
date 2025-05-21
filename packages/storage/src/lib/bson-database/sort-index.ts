//
// Implements a sorted index for a BSON collection with support for pagination
//

import crypto from 'crypto';
import { BSON } from 'bson';
import { IRecord, IBsonCollection } from './collection';
import { IStorage } from '../storage';
import { retry } from 'utils';
import fs from 'fs-extra';
import os from 'os';
import path from 'path';

export interface ISortedIndexEntry<RecordT> {
    // The ID of the record
    recordId: string; //TODO: this should be a UUID buffer type.

    // The value used for sorting
    value: any;
    
    // The complete record - for faster retrieval without loading from collection
    record: RecordT;
}

export interface ISortIndexOptions {
    // Interface to the file storage system
    storage: IStorage;

    // The directory where sorted indexes are stored
    baseDirectory: string;

    // The collection name
    collectionName: string;

    // The name of the field to sort by
    fieldName: string;

    // Sort direction: 'asc' or 'desc'
    direction: 'asc' | 'desc';

    // Number of records per page
    pageSize?: number;
}

export interface ISortResult<RecordT> {
    // Records for the requested page
    records: RecordT[];

    // Total number of records in the collection
    totalRecords: number;

    // Current page number (1-based)
    currentPage: number;

    // Total number of pages
    totalPages: number;

    // Next page number or undefined if this is the last page
    nextPage?: number;

    // Previous page number or undefined if this is the first page
    previousPage?: number;
}

export class SortIndex<RecordT extends IRecord> {
    private storage: IStorage;
    private indexDirectory: string;
    private fieldName: string;
    private direction: 'asc' | 'desc';
    private pageSize: number;
    private totalEntries: number = 0;
    private dirty: boolean = false;
    private initialized: boolean = false;

    constructor(options: ISortIndexOptions) {
        this.storage = options.storage;
        this.indexDirectory = `${options.baseDirectory}/sort_indexes/${options.collectionName}/${options.fieldName}_${options.direction}`;
        this.fieldName = options.fieldName;
        this.direction = options.direction;
        this.pageSize = options.pageSize || 1000;
    }
    
    // Initialize or update the index using external sorting to handle large collections
    async initialize(collection: IBsonCollection<RecordT>): Promise<void> {
        // console.log(`Initializing sort index for field '${this.fieldName}' (${this.direction})`);
        
        const CHUNK_SIZE = 1000; // Number of records to process at once
        const localTmpDir = path.join(os.tmpdir(), `bsondb_sort_${Date.now()}`);
        
        // Create local temporary directory
        await fs.ensureDir(localTmpDir);

        // console.log(`Using temporary directory: ${localTmpDir}`);
        
        let recordCount = 0;
        let chunkCount = 0;
        let totalRecords = 0;
        
        // Step 1: Create sorted chunks
        // console.log("Phase 1: Creating sorted chunks...");
        let currentChunk: ISortedIndexEntry<RecordT>[] = [];
        
        // Iterate through all records in the collection
        for await (const record of collection.iterateRecords()) { //todo: It's not really ncessary to put records into chunks here. Given that the records are already sharded into chunks!
            const value = record[this.fieldName];

            // Skip records where the field doesn't exist
            if (value === undefined) {
                continue;
            }
            
            currentChunk.push({
                recordId: record._id,
                value: value,
                record: record
            });

            recordCount++;
            totalRecords++;
            
            // When we have enough records, sort and save this chunk to local storage
            if (currentChunk.length >= CHUNK_SIZE) {
                await this.sortAndSaveChunk(currentChunk, chunkCount, localTmpDir);
                chunkCount++;
                currentChunk = [];
                console.log(`Processed ${recordCount} records. Created chunk #${chunkCount}`);
            }
        }
        
        // Save the last chunk if it has any records
        if (currentChunk.length > 0) {
            await this.sortAndSaveChunk(currentChunk, chunkCount, localTmpDir);
            chunkCount++;
            console.log(`Processed ${recordCount} records. Created final chunk #${chunkCount}`);
        }
        
        // No records to sort
        if (chunkCount === 0) {
            // console.log("No records found with the specified field. Creating empty index.");
            this.totalEntries = 0;
            await this.saveMetadata();
            this.initialized = true;
            this.dirty = false;
            return;
        }
        
        // Step 2: Merge sorted chunks into pages
        console.log("Phase 2: Merging sorted chunks into pages...");
        
        // Set total entries for metadata
        this.totalEntries = totalRecords;
                
        // Perform a k-way merge using local temporary files
        await this.mergeChunks(chunkCount, localTmpDir);
        
        // Save metadata
        await this.saveMetadata();
        
        // Clean up temporary directory
        await fs.remove(localTmpDir);
        
        // console.log(`Completed initializing sort index for field '${this.fieldName}' (${this.direction})`);

        const totalPages = Math.ceil(this.totalEntries / this.pageSize);
        console.log(`Total records: ${totalRecords}, Total pages: ${totalPages}`);
        
        this.initialized = true;
        this.dirty = false;
    }
    
    // Helper method to sort and save a chunk of data
    private async sortAndSaveChunk(chunk: ISortedIndexEntry<RecordT>[], chunkIndex: number, tmpDir: string): Promise<void> {
        // Sort the chunk
        chunk.sort((a, b) => {
            if (a.value < b.value) {
                return this.direction === 'asc' ? -1 : 1;
            }
            if (a.value > b.value) {
                return this.direction === 'asc' ? 1 : -1;
            }
            return 0;
        });
        
        // Save the sorted chunk
        const chunkPath = `${tmpDir}/chunk_${chunkIndex}.dat`;
        await this.saveChunkFile(chunkPath, chunk);
    }
    
    // Helper method to save a chunk file to local storage
    private async saveChunkFile(filePath: string, entries: ISortedIndexEntry<RecordT>[]): Promise<void> {
        // Write to local file storage
        await fs.writeFile(filePath, BSON.serialize({ entries }));
    }
    
    // Helper method to load a chunk file from local storage
    private async loadChunkFile(filePath: string): Promise<ISortedIndexEntry<RecordT>[]> {
        let fileData: Buffer;
        
        try {
            fileData = await fs.readFile(filePath);
        } catch (err) {
            console.error(`Failed to read chunk file: ${filePath}`, err);
            return [];
        }
        
        if (!fileData || fileData.length === 0) {
            return [];
        }       
        
        // Deserialize the page data
        const chunkData = BSON.deserialize(fileData) as { entries: ISortedIndexEntry<RecordT>[] };
        return chunkData.entries;
    }
    
    // Merges sorted chunks into pages
    private async mergeChunks(chunkCount: number, localTmpDir: string): Promise<void> {
        // Create chunk readers - we'll load chunks on demand instead of all at once
        const chunkReaders: Array<{
            path: string,
            currentEntry: ISortedIndexEntry<RecordT> | null,
            exhausted: boolean
        }> = [];
        
        // Initialize chunk readers
        for (let i = 0; i < chunkCount; i++) {
            const chunkPath = `${localTmpDir}/chunk_${i}.dat`;
            const chunkEntries = await this.loadChunkFile(chunkPath);
            
            chunkReaders.push({
                path: chunkPath,
                currentEntry: chunkEntries.length > 0 ? chunkEntries[0] : null,
                exhausted: chunkEntries.length === 0
            });
        }
        
        // Process page by page
        let currentPage = 0;
        let entriesInCurrentPage = 0;
        let currentPageEntries: ISortedIndexEntry<RecordT>[] = [];
        
        // Process all entries from all chunks
        while (true) {
            // Find chunk with the smallest next value
            let smallestChunkIndex = -1;
            let smallestEntry: ISortedIndexEntry<RecordT> | null = null;
            
            for (let i = 0; i < chunkReaders.length; i++) {
                const reader = chunkReaders[i];
                
                // Skip exhausted readers
                if (reader.exhausted) {
                    continue;
                }
                
                const entry = reader.currentEntry;
                
                // If this is the first valid entry or it's smaller than current smallest
                if (smallestEntry === null || this.compareValues(entry!.value, smallestEntry.value) < 0) {
                    smallestEntry = entry;
                    smallestChunkIndex = i;
                }
            }
            
            // If no valid entry found, we're done
            if (smallestChunkIndex === -1) {
                break;
            }
            
            // Add the smallest entry to current page
            currentPageEntries.push(smallestEntry!);
            entriesInCurrentPage++;
            
            // Advance to next entry in the selected chunk
            const reader = chunkReaders[smallestChunkIndex];
            const chunkPath = reader.path;
            
            // Load the chunk and find the next entry
            const entries = await this.loadChunkFile(chunkPath);
            const currentEntryIndex = entries.findIndex(e => e.recordId === smallestEntry!.recordId);
            
            if (currentEntryIndex !== -1 && currentEntryIndex + 1 < entries.length) {
                // Move to next entry
                reader.currentEntry = entries[currentEntryIndex + 1];
            } else {
                // Reached end of chunk
                reader.currentEntry = null;
                reader.exhausted = true;
            }
            
            // If current page is full, save it to the remote storage and start a new one
            if (entriesInCurrentPage >= this.pageSize) {
                await this.savePageFile(currentPage, currentPageEntries);
                currentPage++;
                currentPageEntries = [];
                entriesInCurrentPage = 0;
                
                if (currentPage % 10 === 0) {
                    console.log(`Saved ${currentPage} pages.`);
                }
            }
        }
        
        // Save last page if it contains any entries
        if (currentPageEntries.length > 0) {
            await this.savePageFile(currentPage, currentPageEntries);
        }
    }
    
    // Helper for comparing values consistently
    private compareValues(a: any, b: any): number {
        if (a < b) {
            return this.direction === 'asc' ? -1 : 1;
        }
        if (a > b) {
            return this.direction === 'asc' ? 1 : -1;
        }
        return 0;
    }
    
    // Save page file to storage
    private async savePageFile(pageNum: number, entries: ISortedIndexEntry<RecordT>[]): Promise<void> {
        const filePath = `${this.indexDirectory}/page_${pageNum}.dat`;

        // Serialize the entries
        const bsonData = BSON.serialize({ entries });

        // Add a version number (4 bytes) at the beginning
        const versionBuffer = Buffer.alloc(4);
        versionBuffer.writeUInt32LE(1, 0); // Version 1

        // Combine version and BSON data
        const versionedData = Buffer.concat([versionBuffer, bsonData]);

        // Calculate checksum
        const checksum = crypto.createHash('sha256').update(versionedData).digest();

        // Combine versioned data and checksum
        const dataWithChecksum = Buffer.concat([versionedData, checksum]);

        // Write to storage
        await this.storage.write(filePath, undefined, dataWithChecksum);

        // Verify the write
        const readBuffer = await retry(() => this.storage.read(filePath));
        if (!readBuffer) {
            throw new Error(`Page file verification failed (file not found): ${filePath}`);
        }

        if (readBuffer.length !== dataWithChecksum.length) {
            throw new Error(`Page file verification failed (size mismatch: ${readBuffer.length} vs ${dataWithChecksum.length})`);
        }

        // console.log(`Saved page ${pageNum} with ${entries.length} entries to ${filePath}`);
    }

    // Save metadata file with total records and other info
    private async saveMetadata(): Promise<void> {
        const metadataPath = `${this.indexDirectory}/metadata.dat`;

        const metadata = {
            fieldName: this.fieldName,
            direction: this.direction,
            pageSize: this.pageSize,
            totalEntries: this.totalEntries,
            totalPages: Math.ceil(this.totalEntries / this.pageSize),
            createdAt: new Date(),
            lastUpdatedAt: new Date()
        };

        // Serialize the metadata
        const bsonData = BSON.serialize(metadata);

        // Add a version number
        const versionBuffer = Buffer.alloc(4);
        versionBuffer.writeUInt32LE(1, 0); // Version 1

        // Combine version and BSON data
        const versionedData = Buffer.concat([versionBuffer, bsonData]);

        // Calculate checksum
        const checksum = crypto.createHash('sha256').update(versionedData).digest();

        // Combine versioned data and checksum
        const dataWithChecksum = Buffer.concat([versionedData, checksum]);

        // Write to storage
        await this.storage.write(metadataPath, undefined, dataWithChecksum);
    }

    // Load metadata file
    private async loadMetadata(): Promise<{
        totalEntries: number;
        totalPages: number;
        pageSize: number;
        lastUpdatedAt?: Date;
    } | undefined> {
        const metadataPath = `${this.indexDirectory}/metadata.dat`;

        if (await this.storage.fileExists(metadataPath)) {
            const fileData = await this.storage.read(metadataPath);

            if (fileData && fileData.length > 0) {
                // Skip the 32-byte checksum at the end
                const dataWithoutChecksum = fileData.subarray(0, fileData.length - 32);

                // Calculate checksum of the data
                const storedChecksum = fileData.subarray(fileData.length - 32);
                const calculatedChecksum = crypto.createHash('sha256').update(dataWithoutChecksum).digest();

                // Verify checksum
                if (!calculatedChecksum.equals(storedChecksum)) {
                    console.error('Metadata checksum verification failed');
                    return undefined;
                }

                // Read version number (first 4 bytes)
                const version = dataWithoutChecksum.readUInt32LE(0);

                if (version === 1) {
                    // Skip the version number to get to the BSON data
                    const bsonData = dataWithoutChecksum.subarray(4);

                    // Deserialize the metadata
                    const metadata = BSON.deserialize(bsonData);
                    return {
                        totalEntries: metadata.totalEntries,
                        totalPages: metadata.totalPages,
                        pageSize: metadata.pageSize,
                        lastUpdatedAt: metadata.lastUpdatedAt
                    };
                }
            }
        }

        return undefined;
    }

    // Load a specific page file
    private async loadPageFile(pageNum: number): Promise<ISortedIndexEntry<RecordT>[] | undefined> {
        const filePath = `${this.indexDirectory}/page_${pageNum}.dat`;

        if (await this.storage.fileExists(filePath)) {
            const fileData = await this.storage.read(filePath);

            if (fileData && fileData.length > 0) {
                // Skip the 32-byte checksum at the end
                const dataWithoutChecksum = fileData.subarray(0, fileData.length - 32);

                // Calculate checksum of the data
                const storedChecksum = fileData.subarray(fileData.length - 32);
                const calculatedChecksum = crypto.createHash('sha256').update(dataWithoutChecksum).digest();

                // Verify checksum
                if (!calculatedChecksum.equals(storedChecksum)) {
                    console.error(`Page file checksum verification failed: ${filePath}`);
                    return undefined;
                }

                // Read version number (first 4 bytes)
                const version = dataWithoutChecksum.readUInt32LE(0);

                if (version === 1) {
                    // Skip the version number to get to the BSON data
                    const bsonData = dataWithoutChecksum.subarray(4);

                    // Deserialize the page data
                    const pageData = BSON.deserialize(bsonData) as { entries: ISortedIndexEntry<RecordT>[] };

                    return pageData.entries;
                }
            }
        }

        return undefined;
    }

    // Check if the index is initialized
    async isInitialized(): Promise<boolean> {
        if (this.initialized) {
            return true;
        }

        // Check if metadata file exists
        const metadataPath = `${this.indexDirectory}/metadata.dat`;
        return await this.storage.fileExists(metadataPath);
    }

    // Get a page of records from the collection using the sort index
    async getPage(collection: IBsonCollection<RecordT>, page: number = 1): Promise<ISortResult<RecordT>> {
        // Check if initialized
        const isInit = await this.isInitialized();
        if (!isInit) {
            await this.initialize(collection);
        }

        // Load metadata
        const metadata = await this.loadMetadata();
        if (!metadata) {
            throw new Error(`Failed to load metadata for sort index '${this.fieldName}'`);
        }

        const { totalEntries, totalPages, pageSize } = metadata;

        // Validate page number
        if (page < 1) {
            page = 1;
        } 
        else if (page > totalPages) {
            return {
                records: [],
                totalRecords: totalEntries,
                currentPage: page,
                totalPages,
                nextPage: undefined,
                previousPage: undefined
            };
        }

        // Calculate zero-based page number
        const pageIndex = page - 1;

        // Load page entries
        const pageEntries = await this.loadPageFile(pageIndex);
        if (!pageEntries) {
            throw new Error(`Failed to load page ${page} for sort index '${this.fieldName}'`);
        }
        
        // Use the stored records directly from the sort index
        const records: RecordT[] = [];
        for (const entry of pageEntries) {
            records.push(entry.record);
        }

        // Return the result with pagination info
        return {
            records,
            totalRecords: totalEntries,
            currentPage: page,
            totalPages,
            nextPage: page < totalPages ? page + 1 : undefined,
            previousPage: page > 1 ? page - 1 : undefined
        };
    }

    // Get the last updated timestamp for the index
    async getLastUpdatedTimestamp(): Promise<Date | undefined> {
        const metadata = await this.loadMetadata();
        return metadata?.lastUpdatedAt;
    }

    // Check if the index is newer than the given timestamp
    async isNewerThan(timestamp: Date): Promise<boolean> {
        const metadata = await this.loadMetadata();
        if (!metadata || !metadata.lastUpdatedAt) {
            return false;
        }

        return metadata.lastUpdatedAt.getTime() > timestamp.getTime();
    }

    // Delete the entire index
    async delete(): Promise<void> {
        if (await this.storage.dirExists(this.indexDirectory)) {
            await this.storage.deleteDir(this.indexDirectory);
        }

        this.totalEntries = 0;
        this.initialized = false;
    }
    
    /**
     * Updates a record in the index without rebuilding the entire index
     * If the indexed field value has changed, the record will be removed and added again
     */
    async updateRecord(record: RecordT): Promise<void> {
        // Check if initialized
        const isInit = await this.isInitialized();
        if (!isInit) {
            throw new Error(`Sort index for field '${this.fieldName}' is not initialized`);
        }
        
        const recordId = record._id;
        const newValue = record[this.fieldName];
        
        // If the field doesn't exist in the record, remove it from the index
        if (newValue === undefined) {
            await this.deleteRecord(recordId);
            return;
        }
        
        // First, try to delete the record if it exists
        await this.deleteRecord(recordId);
        
        // Then add the record with the new value
        await this.addRecord(record);
    }
    
    /**
     * Deletes a record from the index without rebuilding the entire index
     */
    async deleteRecord(recordId: string): Promise<void> {
        // Check if initialized
        const isInit = await this.isInitialized();
        if (!isInit) {
            throw new Error(`Sort index for field '${this.fieldName}' is not initialized`);
        }
        
        // Load metadata to get total pages
        const metadata = await this.loadMetadata();
        if (!metadata || metadata.totalPages === 0) {
            return; // No pages, nothing to delete
        }
        
        const totalPages = metadata.totalPages;
        
        // Search each page for the record
        for (let pageNum = 0; pageNum < totalPages; pageNum++) {
            const pageEntries = await this.loadPageFile(pageNum);
            if (!pageEntries || pageEntries.length === 0) {
                continue; // Skip empty pages
            }
            
            // Find the record in the page
            const recordIndex = pageEntries.findIndex(entry => entry.recordId === recordId);
            if (recordIndex === -1) {
                continue; // Record not found in this page
            }
            
            // Found the record, remove it from the page
            pageEntries.splice(recordIndex, 1);
            
            // Update the page
            await this.savePageFile(pageNum, pageEntries);
            
            // Decrement total entries
            this.totalEntries--;
            
            // Update metadata
            await this.saveMetadata();
            
            // Record found and deleted, no need to check more pages
            break;
        }
    }
    
    /**
     * Adds a new record to the index without rebuilding the entire index
     */
    async addRecord(record: RecordT): Promise<void> {
        // Check if initialized
        const isInit = await this.isInitialized();
        if (!isInit) {
            // If not initialized, initialize with this single record
            const collection = {
                iterateRecords: async function* () {
                    yield record;
                }
            } as IBsonCollection<RecordT>;
            
            await this.initialize(collection);
            return;
        }
        
        const recordId = record._id;
        const value = record[this.fieldName];
        
        // If the field doesn't exist in the record, don't add it to the index
        if (value === undefined) {
            return;
        }
        
        // Load metadata to get total pages
        const metadata = await this.loadMetadata();
        if (!metadata) {
            throw new Error(`Failed to load metadata for sort index '${this.fieldName}'`);
        }
        
        const { totalPages } = metadata;
        
        if (totalPages === 0) {
            // No pages yet, create the first page
            await this.savePageFile(0, [{
                recordId,
                value,
                record
            }]);
            
            // Update total entries
            this.totalEntries = 1;
            
            // Update metadata
            await this.saveMetadata();
            return;
        }
        
        // Binary search to find the page where the record should be inserted
        let left = 0;
        let right = totalPages - 1;
        let targetPage = 0;
        
        while (left <= right) {
            const mid = Math.floor((left + right) / 2);
            const pageEntries = await this.loadPageFile(mid);
            
            if (!pageEntries || pageEntries.length === 0) {
                targetPage = mid;
                break;
            }
            
            // Check where value belongs
            const firstValue = pageEntries[0].value;
            const lastValue = pageEntries[pageEntries.length - 1].value;
            
            if (this.direction === 'asc') {
                if (value < firstValue) {
                    right = mid - 1;
                    targetPage = mid;
                } else if (value > lastValue) {
                    left = mid + 1;
                    targetPage = left;
                } else {
                    // Value belongs in this page
                    targetPage = mid;
                    break;
                }
            } else {
                // For 'desc' ordering
                if (value > firstValue) {
                    right = mid - 1;
                    targetPage = mid;
                } else if (value < lastValue) {
                    left = mid + 1;
                    targetPage = left;
                } else {
                    // Value belongs in this page
                    targetPage = mid;
                    break;
                }
            }
        }
        
        // Clamp target page to existing pages
        targetPage = Math.min(targetPage, totalPages - 1);
        
        // Load the target page
        let pageEntries = await this.loadPageFile(targetPage);
        if (!pageEntries) {
            pageEntries = [];
        }
        
        // Create the new entry
        const newEntry: ISortedIndexEntry<RecordT> = {
            recordId,
            value,
            record
        };
        
        // Insert the entry in the correct position
        let inserted = false;
        for (let i = 0; i < pageEntries.length; i++) {
            const compareResult = this.compareValues(value, pageEntries[i].value);
            if ((this.direction === 'asc' && compareResult <= 0) ||
                (this.direction === 'desc' && compareResult >= 0)) {
                pageEntries.splice(i, 0, newEntry);
                inserted = true;
                break;
            }
        }
        
        if (!inserted) {
            // Add to the end of the page
            pageEntries.push(newEntry);
        }
        
        // If the page is now too large, split it
        if (pageEntries.length > this.pageSize * 1.2) { // Allow some buffer
            const halfSize = Math.floor(pageEntries.length / 2);
            const newPage = pageEntries.splice(halfSize);
            
            // Save the existing page
            await this.savePageFile(targetPage, pageEntries);
            
            // Create a new page
            await this.savePageFile(totalPages, newPage);
            
            // Increment total entries
            this.totalEntries++;
            
            // Update metadata to reflect the new page
            await this.saveMetadata();
        } else {
            // Save the updated page
            await this.savePageFile(targetPage, pageEntries);
            
            // Increment total entries
            this.totalEntries++;
            
            // Update metadata
            await this.saveMetadata();
        }
    }
    
    // Find records by exact value using binary search on the sorted index
    async findByValue(value: any): Promise<RecordT[]> {
        // Check if initialized
        const isInit = await this.isInitialized();
        if (!isInit) {
            throw new Error(`Sort index for field '${this.fieldName}' is not initialized`);
        }
        
        // Load metadata
        const metadata = await this.loadMetadata();
        if (!metadata) {
            throw new Error(`Failed to load metadata for sort index '${this.fieldName}'`);
        }
        
        const { totalPages } = metadata;
        
        if (totalPages === 0) {
            return []; // No records in the index
        }
        
        // Binary search to find the page containing the value
        let left = 0;
        let right = totalPages - 1;
        let foundPage = -1;
        
        while (left <= right) {
            const mid = Math.floor((left + right) / 2);
            const pageEntries = await this.loadPageFile(mid);
            
            if (!pageEntries || pageEntries.length === 0) {
                break;
            }
            
            // Check if value might be in this page
            const firstValue = pageEntries[0].value;
            const lastValue = pageEntries[pageEntries.length - 1].value;
            
            if (this.direction === 'asc') {
                if (value < firstValue) {
                    right = mid - 1;
                } else if (value > lastValue) {
                    left = mid + 1;
                } else {
                    // Value is within this page's range
                    foundPage = mid;
                    break;
                }
            } else {
                // For 'desc' ordering
                if (value > firstValue) {
                    right = mid - 1;
                } else if (value < lastValue) {
                    left = mid + 1;
                } else {
                    // Value is within this page's range
                    foundPage = mid;
                    break;
                }
            }
        }
        
        if (foundPage === -1) {
            return []; // Value not found
        }
        
        // Load the page and find the exact matches
        const pageEntries = await this.loadPageFile(foundPage);
        if (!pageEntries) {
            return [];
        }
        
        // Binary search within the page for exact matches
        let startIdx = -1;
        let endIdx = -1;
        
        // Find the first occurrence of the value
        left = 0;
        right = pageEntries.length - 1;
        while (left <= right) {
            const mid = Math.floor((left + right) / 2);
            if (pageEntries[mid].value === value) {
                startIdx = mid;
                right = mid - 1; // Look for earlier occurrences
            } else if (this.compareValues(pageEntries[mid].value, value) < 0) {
                left = mid + 1;
            } else {
                right = mid - 1;
            }
        }
        
        if (startIdx === -1) {
            return []; // Value not found
        }
        
        // Find the last occurrence of the value
        left = startIdx;
        right = pageEntries.length - 1;
        endIdx = startIdx; // At minimum, we have one match
        
        while (left <= right) {
            const mid = Math.floor((left + right) / 2);
            if (pageEntries[mid].value === value) {
                endIdx = mid;
                left = mid + 1; // Look for later occurrences
            } else if (this.compareValues(pageEntries[mid].value, value) < 0) {
                left = mid + 1;
            } else {
                right = mid - 1;
            }
        }
        
        // Extract all matching records
        const matchingRecords: RecordT[] = [];
        for (let i = startIdx; i <= endIdx; i++) {
            matchingRecords.push(pageEntries[i].record);
        }
        
        return matchingRecords;
    }
    
    // Find records by range query using binary search
    async findByRange(options: {
        min?: any;
        max?: any;
        minInclusive?: boolean;
        maxInclusive?: boolean;
    }): Promise<RecordT[]> {
        const {
            min = null,
            max = null,
            minInclusive = true,
            maxInclusive = true
        } = options;
        
        // At least one bound must be specified
        if (min === null && max === null) {
            throw new Error('At least one of min or max must be specified for range query');
        }
        
        // Check if initialized
        const isInit = await this.isInitialized();
        if (!isInit) {
            throw new Error(`Sort index for field '${this.fieldName}' is not initialized`);
        }
        
        // Load metadata
        const metadata = await this.loadMetadata();
        if (!metadata) {
            throw new Error(`Failed to load metadata for sort index '${this.fieldName}'`);
        }
        
        const { totalPages } = metadata;
        
        if (totalPages === 0) {
            return []; // No records in the index
        }
        
        // Binary search to find the first page that might contain values in the range
        let firstRelevantPage = 0;
        let lastRelevantPage = totalPages - 1;
        
        // Find first page if min is specified
        if (min !== null) {
            let left = 0;
            let right = totalPages - 1;
            
            while (left <= right) {
                const mid = Math.floor((left + right) / 2);
                const pageEntries = await this.loadPageFile(mid);
                
                if (!pageEntries || pageEntries.length === 0) {
                    // Skip empty pages
                    right = mid - 1;
                    continue;
                }
                
                const firstValue = pageEntries[0].value;
                const lastValue = pageEntries[pageEntries.length - 1].value;
                
                if (this.direction === 'asc') {
                    // For ascending pages
                    if (minInclusive ? lastValue < min : lastValue <= min) {
                        // All values in this page are before min, look in later pages
                        left = mid + 1;
                    } else {
                        // This page might contain values >= min, or pages before it might
                        right = mid - 1;
                        firstRelevantPage = mid;
                    }
                } else {
                    // For descending pages
                    if (minInclusive ? firstValue < min : firstValue <= min) {
                        // All values in this page are before min, look in earlier pages
                        right = mid - 1;
                    } else {
                        // This page might contain values >= min, or pages after it might
                        left = mid + 1;
                        firstRelevantPage = mid;
                    }
                }
            }
        }
        
        // Find last page if max is specified
        if (max !== null) {
            let left = firstRelevantPage;
            let right = totalPages - 1;
            
            while (left <= right) {
                const mid = Math.floor((left + right) / 2);
                const pageEntries = await this.loadPageFile(mid);
                
                if (!pageEntries || pageEntries.length === 0) {
                    // Skip empty pages
                    left = mid + 1;
                    continue;
                }
                
                const firstValue = pageEntries[0].value;
                const lastValue = pageEntries[pageEntries.length - 1].value;
                
                if (this.direction === 'asc') {
                    // For ascending pages
                    if (maxInclusive ? firstValue > max : firstValue >= max) {
                        // All values in this page are after max, look in earlier pages
                        right = mid - 1;
                    } else {
                        // This page might contain values <= max, or pages after it might
                        left = mid + 1;
                        lastRelevantPage = mid;
                    }
                } else {
                    // For descending pages
                    if (maxInclusive ? lastValue > max : lastValue >= max) {
                        // All values in this page are after max, look in later pages
                        left = mid + 1;
                    } else {
                        // This page might contain values <= max, or pages before it might
                        right = mid - 1;
                        lastRelevantPage = mid;
                    }
                }
            }
        }
        
        // If we need to scan multiple pages, we'll collect matching entries here
        const matchingRecords: RecordT[] = [];
        
        // Scan only the relevant page range determined by binary search
        for (let pageNum = firstRelevantPage; pageNum <= lastRelevantPage; pageNum++) {
            const pageEntries = await this.loadPageFile(pageNum);
            
            if (!pageEntries || pageEntries.length === 0) {
                continue;
            }
            
            // Check if this page might contain values in the range
            const firstValue = pageEntries[0].value;
            const lastValue = pageEntries[pageEntries.length - 1].value;
            
            // Skip pages that are entirely outside the range
            if (this.direction === 'asc') {
                // Skip if page is entirely above max
                if (max !== null) {
                    if (maxInclusive && firstValue > max) continue;
                    if (!maxInclusive && firstValue >= max) continue;
                }
                
                // Skip if page is entirely below min
                if (min !== null) {
                    if (minInclusive && lastValue < min) continue;
                    if (!minInclusive && lastValue <= min) continue;
                }
            } else {
                // For 'desc' ordering (values are in descending order)
                // Skip if page is entirely above max (now lastValue)
                if (max !== null) {
                    if (maxInclusive && lastValue > max) continue;
                    if (!maxInclusive && lastValue >= max) continue;
                }
                
                // Skip if page is entirely below min (now firstValue)
                if (min !== null) {
                    if (minInclusive && firstValue < min) continue;
                    if (!minInclusive && firstValue <= min) continue;
                }
            }
            
            // Use binary search within the page to find start and end indices
            let startIdx = 0;
            let endIdx = pageEntries.length - 1;
            
            // Find start index if min is specified
            if (min !== null) {
                let left = 0;
                let right = pageEntries.length - 1;
                let found = false;
                
                while (left <= right) {
                    const mid = Math.floor((left + right) / 2);
                    const value = pageEntries[mid].value;
                    
                    const compare = minInclusive ? 
                        (value >= min) : (value > min);
                        
                    if (compare) {
                        startIdx = mid;
                        found = true;
                        right = mid - 1; // Look for an earlier occurrence
                    } else {
                        left = mid + 1;
                    }
                }
                
                if (!found) continue; // No matching values in this page
            }
            
            // Find end index if max is specified
            if (max !== null) {
                let left = startIdx;
                let right = pageEntries.length - 1;
                let found = false;
                
                while (left <= right) {
                    const mid = Math.floor((left + right) / 2);
                    const value = pageEntries[mid].value;
                    
                    const compare = maxInclusive ? 
                        (value <= max) : (value < max);
                        
                    if (compare) {
                        endIdx = mid;
                        found = true;
                        left = mid + 1; // Look for a later occurrence
                    } else {
                        right = mid - 1;
                    }
                }
                
                if (!found) continue; // No matching values in this page
            }
            
            // Add the matching entries from this page using the range determined by binary search
            for (let i = startIdx; i <= endIdx; i++) {
                const entry = pageEntries[i];
                const value = entry.value;
                
                // Double-check to ensure the value is within the range
                let inRange = true;
                
                if (min !== null) {
                    inRange = minInclusive ? value >= min : value > min;
                }
                
                if (inRange && max !== null) {
                    inRange = maxInclusive ? value <= max : value < max;
                }
                
                if (inRange) {
                    matchingRecords.push(entry.record);
                }
            }
        }
        
        return matchingRecords;
    }
}