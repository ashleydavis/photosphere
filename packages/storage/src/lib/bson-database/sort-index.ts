//
// Implements a sorted index for a BSON collection with support for pagination
//

import crypto from 'crypto';
import { BSON } from 'bson';
import { IRecord, IBsonCollection } from './collection';
import { IStorage } from '../storage';
import { retry } from 'utils';

export interface ISortedIndexEntry<RecordT> {
    // The ID of the record
    recordId: string; //TODO: this should be a UUID buffer type.

    // The value used for sorting
    value: any;
    
    // The complete record
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
    private pageFiles: Map<number, ISortedIndexEntry<RecordT>[]> = new Map();
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

    // Initialize or update the index
    async initialize(collection: IBsonCollection<RecordT>): Promise<void> {
        console.log(`Initializing sort index for field '${this.fieldName}' (${this.direction})`);

        // Create a temporary array to hold all entries
        let recordCount = 0;

        const allEntries: ISortedIndexEntry<RecordT>[] = [];
        
        // Iterate through all records in the collection
        for await (const record of collection.iterateRecords()) {
            const value = record[this.fieldName];

            // Skip records where the field doesn't exist
            if (value === undefined) {
                continue;
            }

            allEntries.push({
                recordId: record._id,
                value: value,
                record: record
            });

            recordCount++;

            if (recordCount % 1000 === 0) {
                console.log(`Read ${recordCount} records.`);
            }
        }

        // Sort the entries
        allEntries.sort((a, b) => {
            if (a.value < b.value) {
                return this.direction === 'asc' ? -1 : 1;
            }
            if (a.value > b.value) {
                return this.direction === 'asc' ? 1 : -1;
            }
            return 0;
        });

        // Divide into pages and save
        this.totalEntries = allEntries.length;
        const totalPages = Math.ceil(this.totalEntries / this.pageSize);

        // Clear existing page files from memory
        this.pageFiles.clear();

        let pageFileCount = 0;

        // Create and save page files
        for (let pageNum = 0; pageNum < totalPages; pageNum++) {
            const start = pageNum * this.pageSize;
            const end = Math.min(start + this.pageSize, allEntries.length);
            const pageEntries = allEntries.slice(start, end);

            // Save to memory
            this.pageFiles.set(pageNum, pageEntries);

            // Save to storage
            await this.savePageFile(pageNum, pageEntries);

            pageFileCount++;

            if (pageFileCount % 10 === 0) {
                console.log(`Saved ${pageFileCount} page files.`);
            }
        }

        // Save metadata
        await this.saveMetadata();

        this.initialized = true;
        this.dirty = false;

        console.log(`Completed initializing sort index for field '${this.fieldName}' (${this.direction})`);
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
        // Check if already loaded in memory
        if (this.pageFiles.has(pageNum)) {
            return this.pageFiles.get(pageNum);
        }

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

                    // Cache in memory
                    this.pageFiles.set(pageNum, pageData.entries);

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
        console.log(`Checking if sort index is initialized: ${metadataPath}`);
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
        } else if (page > totalPages) {
            page = totalPages || 1; // If totalPages is 0, use 1
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

        this.pageFiles.clear();
        this.totalEntries = 0;
        this.initialized = false;
    }
}