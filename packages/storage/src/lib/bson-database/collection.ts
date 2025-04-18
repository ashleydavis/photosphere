//
// A collection in a database that stores BSON records in a sharded format.
//

import crypto from 'crypto';
import { BSON } from 'bson';
import { IStorage } from '../storage';
import { retry } from 'utils';
import { SortManager } from './sort-manager';

//
// Options when creating a BSON collection.
//
export interface IBsonCollectionOptions {
    //
    // Interface to the file storage system.
    //
    storage: IStorage;

    //
    // The directory where the collection is stored.
    //
    directory: string;

    //
    // The number of shards to use for the collection.
    //
    numShards?: number;

    //
    // The maximum number of shards to keep in memory.
    //
    maxCachedShards?: number;
}

export interface IRecord {
    _id: string;
    [key: string]: any;
}

interface IShard<RecordT extends IRecord> {
    id: number;
    dirty: boolean;
    lastAccessed: number;
    records: Map<string, RecordT>;
}

const saveDebounceMs = 300;
const maxSaveDelayMs = 1000;

export interface IBsonCollection<RecordT extends IRecord> {

    //
    // Insert a new record into the collection.
    //
    insertOne(record: RecordT): Promise<void>;

    //
    // Gets one record by ID.
    //
    getOne(id: string): Promise<RecordT | undefined>;

    //
    // Iterate all records in the collection without loading all into memory.
    //
    iterateRecords(): AsyncGenerator<RecordT, void, unknown>;

    //
    // Gets records from the collection with pagination and continuation support.
    // @param continuation Optional token to continue from a previous query
    // @returns An object containing records from one shard and a continuation token for the next query
    //
    getAll(next?: string): Promise<{
        records: RecordT[],
        next?: string
    }>;

    //
    // Get records sorted by a specified field.
    // @param fieldName The field to sort by
    // @param options Options for sorting including direction and pagination
    // @returns Paginated sorted records with metadata
    //
    getSorted(fieldName: string, options?: {
        direction?: 'asc' | 'desc';
        page?: number;
        pageSize?: number
    }): Promise<{
        records: RecordT[];
        totalRecords: number;
        currentPage: number;
        totalPages: number;
        nextPage?: number;
        previousPage?: number;
    }>;

    //
    // Create or rebuild a sort index for the specified field
    // @param fieldName The field to create a sort index for
    // @param direction The sort direction
    //
    ensureSortIndex(fieldName: string, direction?: 'asc' | 'desc'): Promise<void>;

    //
    // List all sort indexes for this collection
    //
    listSortIndexes(): Promise<Array<{
        fieldName: string;
        direction: 'asc' | 'desc';
    }>>;

    //
    // Delete a sort index
    //
    deleteSortIndex(fieldName: string, direction: 'asc' | 'desc'): Promise<boolean>;

    //
    // Updates a record.
    //
    updateOne(id: string, updates: Partial<RecordT>, options?: { upsert?: boolean }): Promise<boolean>

    //
    // Replaces a record with completely new data.
    //
    replaceOne(id: string, record: RecordT, options?: { upsert?: boolean }): Promise<boolean>;

    //
    // Deletes a record.
    //
    deleteOne(id: string): Promise<boolean>;

    //
    // Creates an index for the given field (alias for ensureSortIndex with 'asc' direction)
    //
    ensureIndex(fieldName: string): Promise<void>;

    //
    // Checks if a sort index exists for the given field name
    //
    hasIndex(fieldName: string, direction: "asc" | "desc"): Promise<boolean>;

    //
    // List all indexes for this collection
    //
    listIndexes(): Promise<string[]>;

    //
    // Find records by index
    //
    findByIndex(fieldName: string, value: any): Promise<RecordT[]>;

    //
    // Deletes an index
    //
    deleteIndex(fieldName: string): Promise<boolean>;

    //
    // Writes all pending changes and shuts down the collection.
    //
    shutdown(): Promise<void>;

    //
    // Drops the whole collection.
    //
    drop(): Promise<void>;
}

export class BsonCollection<RecordT extends IRecord> implements IBsonCollection<RecordT> {
    private storage: IStorage;
    private directory: string;
    private numShards: number;
    private shardCache: Map<number, IShard<RecordT>> = new Map();
    private isAlive: boolean = true;
    private maxCachedShards: number;
    private sortManager: SortManager | undefined;

    //
    // The last time the collection was saved.
    //
    private lastSaveTime: number | undefined = undefined;

    constructor(options: IBsonCollectionOptions) {
        this.storage = options.storage;
        this.directory = options.directory;
        this.numShards = options.numShards || 100;
        this.maxCachedShards = options.maxCachedShards || 10;

        // Create the sort manager for this collection
        this.sortManager = new SortManager({
            storage: this.storage,
            baseDirectory: this.directory.split('/').slice(0, -1).join('/') // Parent directory
        });

        this.keepWorkerAlive();
    }

    //
    // Delete all sort indexes for this collection
    //
    private async deleteAllSortIndexes(): Promise<void> {
        if (!this.sortManager) {
            return;
        }

        // Get the collection name
        const collectionName = this.directory.split('/').pop() || '';

        // Delete all sort indexes
        await this.sortManager.deleteAllSortIndexes(collectionName);
    }
    
    //
    // Checks if a sort index exists for the given field
    //
    private async sortIndexExists(fieldName: string, direction: "asc" | "desc"): Promise<boolean> {
        if (!this.sortManager) {
            return false;
        }
        
        const collectionName = this.directory.split('/').pop() || '';
        
        const index = await this.sortManager.getSortIndex<RecordT>(
            collectionName,
            fieldName,
            direction
        );
       
        return !!index;
    }

    //
    // Put id through a buffer and be sure it's in standarized v4 format.
    //
    private normalizeId(id: string) {
        const idBuffer = Buffer.from(id.replace(/-/g, ''), "hex");
        if (idBuffer.length !== 16) {
            throw new Error(`Invalid record ID ${id} with length ${idBuffer.length}`);
        }

        const normalizedId = idBuffer.toString("hex");
        return normalizedId;
    }

    //
    // Adds a record to the shard cache.
    //
    private setRecord(id: string, record: RecordT, shard: IShard<any>): void {
        const normalizedId = this.normalizeId(id);
        shard.records.set(normalizedId, record);
        shard.dirty = true;
        shard.lastAccessed = Date.now();
    }

    //
    // Gets a record from the shard cache.
    //
    private getRecord(id: string, shard: IShard<any>): RecordT | undefined {
        const normalizedId = this.normalizeId(id);
        return shard.records.get(normalizedId);
    }

    //
    // Deletes a record from the shard cache.
    //
    private deleteRecord(id: string, shard: IShard<any>): void {
        const normalizedId = this.normalizeId(id);
        shard.records.delete(normalizedId);
        shard.dirty = true;
        shard.lastAccessed = Date.now();
    }

    //
    // Save all dirty shards.
    //
    private async saveDirtyShards(): Promise<void> {

        // console.log(`Saving dirty shards.`);

        const dirtyShards = Array.from(this.shardCache.values()).filter(shard => shard.dirty);
        if (dirtyShards.length === 0) {
            // console.log(`No dirty shards to save.`);
            return;
        }

        const promises = dirtyShards
            .map(async shard => {
                const filePath = `${this.directory}/${shard.id}`;
                await this.saveShardFile(filePath, shard);
                shard.dirty = false;

                // console.log(`  Saved shard ${shard.id}`);
            });
        await Promise.all(promises);

        // console.log(`Saved ${dirtyShards.length} dirty shards.`);

        this.lastSaveTime = Date.now();

        //
        // Now that we have saved we can evict the oldest shards.
        //
        this.evictOldestShards();
    }

    //
    // Evict oldest shards that are not dirty.
    //
    private evictOldestShards(): void {
        const numShardsToExict = this.shardCache.size - this.maxCachedShards;

        //
        // Sort non-dirty shards by last accessed time.
        //
        const sortedShards = Array.from(this.shardCache.values())
            .filter(shard => !shard.dirty)
            .sort((a, b) => a.lastAccessed - b.lastAccessed);

        //
        // Remove the oldest shards.
        //
        for (let i = 0; i < numShardsToExict && i < sortedShards.length; i++) {
            // console.log(`Evicting shard ${sortedShards[i].id} last accessed at ${sortedShards[i].lastAccessed}`);
            const shard = sortedShards[i];
            this.shardCache.delete(shard.id);
        }
    }

    //
    // Resolves the worker wait promise, waking it up to perform a save.
    //
    private resolveWorkerPromise: (() => void) | undefined = undefined;

    //
    // Loops and saves all records in the cache.
    //
    private async startWorker(): Promise<void> {

        // console.log(`Worker started.`);

        while (this.isAlive) {

            // console.log(`Worker waiting.`);

            //
            // Wait for notification to save.
            //
            await new Promise<void>(resolve => {
                this.resolveWorkerPromise = resolve;
            });

            this.resolveWorkerPromise = undefined;

            if (!this.isAlive) {
                // Exit the worker if the collection is shutting down.
                console.log(`Worker exiting on shutdown.`);
                break;
            }

            // console.log(`Worker triggered saving.`);

            await this.saveDirtyShards();
        }
    }

    //
    // Wakes the worker to save records.
    //
    private wakeWorker(): void {
        if (this.resolveWorkerPromise) {
            this.resolveWorkerPromise();
        }
    }

    //
    // Time for the next scheduled save or undefined if not scheduled.
    //
    private saveTimer: NodeJS.Timeout | undefined;

    //
    // Schedules the worker to wake up and save record.
    //
    private scheduleSave(reason: string): void {

        // console.log(`Scheduling save because ${reason}`);

        this.clearSchedule();

        if (this.lastSaveTime === undefined) {
            this.lastSaveTime = Date.now();
            // console.log(`Set last save time for the first time: ${this.lastSaveTime}`);
        }
        else {
            const timeNow = Date.now();
            const timeSinceLastSaveMs = timeNow - this.lastSaveTime;
            // console.log(`Time since last save: ${(timeSinceLastSaveMs)}ms, Time now: ${timeNow}`);

            if (timeSinceLastSaveMs > maxSaveDelayMs) {
                // console.log(`Too much time elapsed, forcing immediate save.`);
                this.wakeWorker(); // Waker the worker to perform an immediate save. Too much time has passed.
                return;
            }
        }

        //
        // Start a new timer for debounced save.
        //
        this.saveTimer = setTimeout(() => {
            this.saveTimer = undefined;
            // console.log(`Scheduled save triggered.`);
            this.wakeWorker(); // Waker the worker to perform the save.
        }, saveDebounceMs);
    }

    //
    // Clear any current schedule.
    //
    private clearSchedule(): void {
        if (this.saveTimer) {

            // console.log(`Cleared schedule.`);

            clearTimeout(this.saveTimer);
            this.saveTimer = undefined;
        }
    }

    //
    // Keeps the worker alive, even when it has failed.
    //
    private keepWorkerAlive(): void {
        this.startWorker()
            .catch((err: any) => {
                console.error("Worker failed.");
                console.error(err.stack);

                this.keepWorkerAlive();
            });
    }

    //
    // Writes all pending changes and shuts down the collection.
    //
    async shutdown(): Promise<void> {
        console.log(`Shutting down collection.`);
        this.clearSchedule(); // Clear any pending saves.
        this.isAlive = false; // Causes the worker to exit after saving.
        this.wakeWorker(); // Wake the worker so it can exit.
        await this.saveDirtyShards(); // Save any remaining dirty shards.
        
        // Nothing to shut down - we're using SortIndex directly
    }

    //
    // Determines the shard ID for a record based on its ID.
    //
    private generateShardId(recordId: string): number {
        const recordIdBuffer = Buffer.from(recordId.replace(/-/g, ''), 'hex');
        if (recordIdBuffer.length !== 16) {
            throw new Error(`Invalid record ID ${recordId} with length ${recordIdBuffer.length}`);
        }

        const hash = crypto.createHash('md5').update(recordIdBuffer).digest('hex');
        const decimal = parseInt(hash.substring(0, 8), 16);
        return decimal % this.numShards;
    }

    //
    // Calculate checksum for a buffer.
    //
    private calculateChecksum(buffer: Uint8Array): Buffer {
        return crypto.createHash('sha256').update(buffer).digest();
    }

    //
    // Saves the shard file to storage.
    //
    private async saveShardFile(shardFilePath: string, shard: IShard<RecordT>): Promise<void> {
        if (shard.records.size === 0) {
            if (await this.storage.fileExists(shardFilePath)) {
                //
                // Delete empty files.
                //
                await this.storage.deleteFile(shardFilePath);
            }
        }
        else {
            await this.writeBsonFile(shardFilePath, shard);
        }
    }

    //
    // Writes a shard to disk.
    //
    private async writeBsonFile(filePath: string, shard: IShard<RecordT>): Promise<void> {

        const buffers: Uint8Array[] = [];

        const header = Buffer.alloc(4 * 2);
        header.writeUInt32LE(1, 0); // Version
        header.writeUInt32LE(shard.records.size, 4); // Record count
        buffers.push(header);

        for (const record of shard.records.values()) {
            const recordIdBuffer = Buffer.from(record._id.replace(/-/g, ''), 'hex');
            if (recordIdBuffer.length !== 16) {
                throw new Error(`Invalid record ID ${record._id} with length ${recordIdBuffer.length}`);
            }
            buffers.push(recordIdBuffer);

            const recordNoId: any = { ...record };
            delete recordNoId._id; // Remove the id, no need to store it twice.
            const recordBson = BSON.serialize(recordNoId);

            const recordHeader = Buffer.alloc(4);
            recordHeader.writeUInt32LE(recordBson.length, 0);
            buffers.push(recordHeader);
            buffers.push(recordBson);
        }

        const allData = Buffer.concat(buffers);
        const allDataChecksum = this.calculateChecksum(allData);
        if (allDataChecksum.length !== 32) {
            throw new Error(`Checksum length mismatch: ${allDataChecksum.length}`);
        }
        const dataWithChecksum = Buffer.concat([allData, allDataChecksum]);

        //
        // Writes the file.
        //
        await this.storage.write(filePath, undefined, dataWithChecksum);

        //
        // Read the file back to verify it.
        //
        const readBuffer = await retry(() => this.storage.read(filePath));
        if (!readBuffer) {
            throw new Error(`Verification failed (file not found)`);
        }

        //
        // Check the file size matches.
        //
        if (readBuffer.length !== dataWithChecksum.length) {
            throw new Error(`Verification failed (size mismatch: ${readBuffer.length} vs ${dataWithChecksum.length})`);
        }

        //
        // Then verify the checksum.
        //
        const writtenHeaderChecksum = readBuffer.slice(readBuffer.length-32);
        if (!writtenHeaderChecksum.equals(allDataChecksum)) {
            throw new Error(`Verification failed (data checksum mismatch)`);
        }
        const writtenData = readBuffer.slice(0, readBuffer.length-32);
        const computedChecksum = this.calculateChecksum(writtenData);
        if (!computedChecksum.equals(allDataChecksum)) {
            throw new Error(`Verification failed (computed checksum mismatch)`);
        }
    }

    //
    // Reads a single record from the file data and returns the new offset.
    //
    private readRecord(fileData: Buffer<ArrayBufferLike>, offset: number): { record: RecordT, offset: number } {

        //
        // Read 16 byte uuid.
        //
        const recordIdBuffer = fileData.subarray(offset, offset + 16);
        const hexString = recordIdBuffer.toString('hex');
        const recordId = [
            hexString.substring(0, 8),
            hexString.substring(8, 12),
            hexString.substring(12, 16),
            hexString.substring(16, 20),
            hexString.substring(20)
        ].join('-');
        offset += 16;

        //
        // Read the record length.
        //
        const recordLength = fileData.readUInt32LE(offset);
        offset += 4;

        //
        // Read and deserialize the record.
        //
        const recordData = fileData.subarray(offset, offset + recordLength);
        const record = BSON.deserialize(recordData) as RecordT;
        record._id = recordId;
        offset += recordLength;
        return { record, offset };
    }

    //
    // Loads all records from a shard file.
    //
    private async loadRecords(shardFilePath: string): Promise<RecordT[]> {

        let records: RecordT[] = [];

        if (await this.storage.fileExists(shardFilePath)) {
            // Read all records from the file
            const fileData = await this.storage.read(shardFilePath);
            if (fileData && fileData.length > 0) {

                const version = fileData.readUInt32LE(0); // Version

                const recordCount = fileData.readUInt32LE(4); // Record count
                let offset = 8; // Skip the version and record count.

                for (let i = 0; i < recordCount; i++) {
                    const { record, offset: newOffset } = this.readRecord(fileData, offset);
                    records.push(record);
                    offset = newOffset;
                }
            }
        }

        return records;
    }

    //
    // Loads the requested shard from cache or from storage.
    //
    private async loadShard(shardId: number): Promise<IShard<RecordT>> {
        let shard = this.shardCache.get(shardId);
        if (shard === undefined) {
            const filePath = `${this.directory}/${shardId}`;
            const records = await this.loadRecords(filePath);
            shard = {
                id: shardId,
                dirty: false,
                lastAccessed: Date.now(),
                records: new Map<string, RecordT>(),
            };
            for (const record of records) {
                this.setRecord(record._id, record, shard);
            }
            this.shardCache.set(shardId, shard);

            //
            // If we are over the maximum now, evict the oldest shards that have already been saved.
            // If all loaded shards are dirty, then we will have to wait for them to be saved.
            //
            this.evictOldestShards();
        }
        else {
            // console.log(`Found shard ${shardId} in cache.`);
            shard.lastAccessed = Date.now();
        }

        return shard;
    }

    //
    // Insert a new record into the collection.
    //
    async insertOne(record: RecordT): Promise<void> {
        if (!record._id) {
            record._id = crypto.randomUUID();
        }

        const shardId = this.generateShardId(record._id);
        const shard = await this.loadShard(shardId);

        this.setRecord(record._id, record, shard);

        // Delete all sort indexes since the data has changed
        await this.deleteAllSortIndexes();

        this.scheduleSave(`inserted record ${record._id}`);
    }

    //
    // Gets one record by ID.
    //
    async getOne(id: string): Promise<RecordT | undefined> {

        const shardId = this.generateShardId(id);
        const shard = await this.loadShard(shardId);
        if (shard.records.size === 0) {
            return undefined; // Empty file.
        }

        const record = this.getRecord(id, shard);
        if (!record) {
            return undefined; // Record not found
        }

        shard.lastAccessed = Date.now();

        return record;
    }

    //
    // Iterate all records in the collection without loading all into memory.
    //
    async *iterateRecords(): AsyncGenerator<RecordT, void, unknown> {

        for (let shardId = 0; shardId < this.numShards; shardId++) {
            let shard = this.shardCache.get(shardId);
            if (shard !== undefined) {
                //
                // The shard is already cached in memory.
                //
                for (const record of shard.records.values()) {
                    yield record;
                }
                continue;
             }

             const buffer = await this.storage.read(`${this.directory}/${shardId}`);
             if (!buffer || buffer.length === 0) {
                 continue;
             }

            const version = buffer.readUInt32LE(0); // Version
            const recordCount = buffer.readUInt32LE(4); // Record count

            let offset = 8; // Skip the version and record count.

            for (let i = 0; i < recordCount; i++) {
                const { record, offset: newOffset } = this.readRecord(buffer, offset);
                yield record;
                offset = newOffset;
            }
        }
    }

    //
    // Gets records from the collection with pagination and continuation support.
    // @param next Optional token to continue from a previous query
    // @returns An object containing records from one shard and a continuation token for the next query
    //
    async getAll(next?: string): Promise<{  records: RecordT[], next?: string }> {

        let shardId = next ? parseInt(next) : 0;
        while (shardId < this.numShards) {
            const shard = this.shardCache.get(shardId);
            if (shard !== undefined) {
                // The shard is already cached in memory
                const records = Array.from(shard.records.values());
                if (records.length > 0) {
                    return { records, next: `${shardId + 1}` };
                }
            }
            else {
                // Load records from storage
                const filePath = `${this.directory}/${shardId}`;
                const records = await this.loadRecords(filePath);
                if (records.length > 0) {
                    return { records, next: `${shardId + 1}` };
                }
            }

            shardId += 1;
        }

        return { records: [], next: undefined }; // No more records
    }

    //
    // Updates a record.
    //
    async updateOne(id: string, updates: Partial<RecordT>, options?: { upsert?: boolean }): Promise<boolean> {
        const shardId = this.generateShardId(id);
        const shard = await this.loadShard(shardId);

        let existingRecord: any = this.getRecord(id, shard);

        if (!options?.upsert) {
            //
            // If not upserting, finds the record to update.
            //

            if (!existingRecord) {
                return false; // Record not found
            }
        }

        if (!existingRecord) {
            existingRecord = {
                _id: id,
            };
        }

        //
        // Updates the record.
        //
        const updatedRecord: any = { ...existingRecord, ...updates };
        this.setRecord(id, updatedRecord, shard);

        // Delete all sort indexes since the data has changed
        await this.deleteAllSortIndexes();

        this.scheduleSave(`updated record ${id}`);

        return true;
    }

    //
    // Replaces a record with completely new data.
    //
    async replaceOne(id: string, record: RecordT, options?: { upsert?: boolean }): Promise<boolean> {
        const shardId = this.generateShardId(id);
        const shard = await this.loadShard(shardId);

        const existingRecord = this.getRecord(id, shard);

        if (!options?.upsert && !existingRecord) {
            //
            // If not upserting, finds the record to update.
            //
            return false; // Record not found
        }

        //
        // Replaces the record.
        //
        this.setRecord(id, record, shard);

        // Delete all sort indexes since the data has changed
        await this.deleteAllSortIndexes();

        this.scheduleSave(`replaced record ${id}`);

        return true;
    }

    //
    // Deletes a record.
    //
    async deleteOne(id: string): Promise<boolean> {
        const shardId = this.generateShardId(id);
        const shard = await this.loadShard(shardId);

        //
        // Find the record to delete.
        //
        const existingRecord = this.getRecord(id, shard);
        if (!existingRecord) {
            return false; // Record not found
        }

        //
        // Delete the record.
        //
        this.deleteRecord(id, shard);

        // Delete all sort indexes since the data has changed
        await this.deleteAllSortIndexes();

        this.scheduleSave(`deleted record ${id}`);

        return true;
    }

    //
    // Creates an index for the given field (alias for ensureSortIndex with 'asc' direction)
    //
    async ensureIndex(fieldName: string): Promise<void> {
        // Just create an ascending sort index
        await this.ensureSortIndex(fieldName, 'asc');
    }

    //
    // Checks if a sort index exists for the given field name
    //
    async hasIndex(fieldName: string, direction: "asc" | "desc"): Promise<boolean> {
        return await this.sortIndexExists(fieldName, direction);
    }

    //
    // List all sort indexes for this collection
    //
    async listIndexes(): Promise<string[]> {
        // Get all sort indexes and extract field names
        const fieldNames = new Set<string>();
        
        if (this.sortManager) {
            const collectionName = this.directory.split('/').pop() || '';
            const sortIndexes = await this.sortManager.listSortIndexes(collectionName);
            
            // Add field names from sort indexes
            for (const index of sortIndexes) {
                fieldNames.add(index.fieldName);
            }
        }
        
        return Array.from(fieldNames);
    }

    //
    // Find records by index using SortIndex
    //
    async findByIndex(fieldName: string, value: any): Promise<RecordT[]> {
        // Check if the sort manager is available
        if (!this.sortManager) {
            throw new Error("Sort manager is required for index operations");
        }
        
        // Get the collection name from the directory path
        const collectionName = this.directory.split('/').pop() || '';
        
        // Try to find an existing sort index for the field (check both asc and desc)
        const ascIndex = await this.sortManager.getSortIndex<RecordT>(
            collectionName,
            fieldName,
            'asc'
        );
        
        if (ascIndex) {
            // Use the sort index for faster search with binary search
            return await ascIndex.findByValue(value);
        }
        
        const descIndex = await this.sortManager.getSortIndex<RecordT>(
            collectionName,
            fieldName,
            'desc'
        );
        
        if (descIndex) {
            // Use the sort index for faster search with binary search
            return await descIndex.findByValue(value);
        }
        
        // If no sort index exists, create one
        await this.ensureSortIndex(fieldName, 'asc');
        
        // Get the newly created sort index
        const newIndex = await this.sortManager.getSortIndex<RecordT>(
            collectionName,
            fieldName,
            'asc'
        );
        
        if (!newIndex) {
            throw new Error(`Failed to create index for field "${fieldName}"`);
        }
        
        // Use the sort index for search
        return await newIndex.findByValue(value);
    }
    
    //
    // Find records where the indexed field is within a range
    //
    async findByRange(
        fieldName: string, 
        options: {
            min?: any;
            max?: any;
            minInclusive?: boolean;
            maxInclusive?: boolean;
            direction?: 'asc' | 'desc';
        }
    ): Promise<RecordT[]> {
        const { direction = 'asc' } = options;
        
        // Require a sort index for range queries
        if (!this.sortManager) {
            throw new Error('Sort manager is required for range queries');
        }
        
        // Get the collection name from the directory path
        const collectionName = this.directory.split('/').pop() || '';
        
        // Try to get the sort index with the specified direction
        let sortIndex = await this.sortManager.getSortIndex<RecordT>(
            collectionName,
            fieldName,
            direction
        );
        
        // If the index doesn't exist, create it
        if (!sortIndex) {
            await this.ensureSortIndex(fieldName, direction);
            sortIndex = await this.sortManager.getSortIndex<RecordT>(
                collectionName,
                fieldName,
                direction
            );
        }
        
        if (!sortIndex) {
            throw new Error(`Failed to create sort index for field '${fieldName}'`);
        }
        
        // Use the sort index's range query method
        return await sortIndex.findByRange(options);
    }

    //
    // Deletes all indexes for a field (both asc and desc)
    //
    async deleteIndex(fieldName: string): Promise<boolean> {
        if (!this.sortManager) {
            return false;
        }
        
        // Get collection name
        const collectionName = this.directory.split('/').pop() || '';
        
        // Delete any existing sort indexes for the field
        let deleted = false;
        
        // Try to delete an ascending index
        const deleteAsc = await this.sortManager.deleteSortIndex(
            collectionName,
            fieldName,
            'asc'
        );
        
        // Try to delete a descending index
        const deleteDesc = await this.sortManager.deleteSortIndex(
            collectionName,
            fieldName,
            'desc'
        );
        
        return deleteAsc || deleteDesc;
    }

    //
    // Get records sorted by a specified field
    //
    async getSorted(fieldName: string, options?: {
        direction?: 'asc' | 'desc';
        page?: number;
        pageSize?: number
    }): Promise<{
        records: RecordT[];
        totalRecords: number;
        currentPage: number;
        totalPages: number;
        nextPage?: number;
        previousPage?: number;
    }> {
        if (!this.sortManager) {
            throw new Error('Sort manager is not initialized');
        }

        // Get the collection name from the directory path
        const collectionName = this.directory.split('/').pop() || '';

        // The sort manager will automatically create the index if it doesn't exist
        return await this.sortManager.getSortedRecords<RecordT>(
            this,
            collectionName,
            fieldName,
            options
        );
    }

    //
    // Create or rebuild a sort index for the specified field
    //
    async ensureSortIndex(fieldName: string, direction: 'asc' | 'desc' = 'asc'): Promise<void> {
        if (!this.sortManager) {
            throw new Error('Sort manager is not initialized');
        }

        if (await this.hasIndex(fieldName, direction)) {
            console.log(`Sort index for field "${fieldName}" already exists.`);
            // Index already exists, no need to create it again.
            return;
        }

        // Get the collection name from the directory path
        const collectionName = this.directory.split('/').pop() || '';

        await this.sortManager.rebuildSortIndex<RecordT>(
            this,
            collectionName,
            fieldName,
            direction
        );
    }

    //
    // List all sort indexes for this collection
    //
    async listSortIndexes(): Promise<Array<{
        fieldName: string;
        direction: 'asc' | 'desc';
    }>> {
        if (!this.sortManager) {
            throw new Error('Sort manager is not initialized');
        }

        // Get the collection name from the directory path
        const collectionName = this.directory.split('/').pop() || '';

        return await this.sortManager.listSortIndexes(collectionName);
    }

    //
    // Delete a sort index
    //
    async deleteSortIndex(fieldName: string, direction: 'asc' | 'desc'): Promise<boolean> {
        if (!this.sortManager) {
            throw new Error('Sort manager is not initialized');
        }

        // Get the collection name from the directory path
        const collectionName = this.directory.split('/').pop() || '';

        return await this.sortManager.deleteSortIndex(
            collectionName,
            fieldName,
            direction
        );
    }

    //
    // Drops the whole collection.
    //
    async drop(): Promise<void> {
        this.clearSchedule(); // Clear any pending saves.
        this.shardCache.clear(); // Clear all shards from memory.
        
        // No need to shutdown indexes - we're only using SortIndex
        // which is managed by SortManager
        
        // Delete sort indexes if any
        if (this.sortManager) {
            const collectionName = this.directory.split('/').pop() || '';
            await this.sortManager.deleteAllSortIndexes(collectionName);
        }

        // Delete the index directory
        const indexDirPath = `${this.directory}/index`;
        if (await this.storage.dirExists(indexDirPath)) {
            await this.storage.deleteFile(indexDirPath);
        }

        // Delete the collection directory
        await this.storage.deleteDir(this.directory);
    }
}