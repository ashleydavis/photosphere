//
// A collection in a database that stores BSON records in a sharded format.
//

import crypto from 'crypto';
import { BSON } from 'bson';
import { IStorage } from '../storage';
import { retry } from 'utils';
import { BsonIndex, IBsonIndex } from './index';

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
    // Gets all records in the collection.
    //
    getAll(skip: number, limit: number): Promise<RecordT[]>;

    //
    // Updates a record.
    //
    updateOne(id: string, updates: Partial<RecordT>, options?: { upsert?: boolean }): Promise<boolean>

    //
    // Replaces a record with completely new data.
    //
    replaceOne(id: string, record: RecordT, options?: { upsert?: boolean }): Promise<boolean>;

    //
    // Creates an index for the given field, but only if it doesn't already exist.
    //
    ensureIndex(fieldName: string): Promise<IBsonIndex<RecordT>>;

    //
    // Gets an existing index by field name
    //
    getIndex(fieldName: string): Promise<IBsonIndex<RecordT> | undefined>;

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
    private indexes: Map<string, IBsonIndex<RecordT>> = new Map();

    //
    // The last time the collection was saved.
    //
    private lastSaveTime: number | undefined = undefined;

    constructor(options: IBsonCollectionOptions) {
        this.storage = options.storage;
        this.directory = options.directory;
        this.numShards = options.numShards || 100;
        this.maxCachedShards = options.maxCachedShards || 10;

        this.keepWorkerAlive();
    }

    // Cache of loaded index field names to avoid checking storage multiple times
    private loadedIndexFields: Set<string> = new Set();
    // Cache of checked but nonexistent index fields
    private nonexistentIndexFields: Set<string> = new Set();
    // Flag to indicate if all indexes have been loaded
    private allIndexesLoaded: boolean = false;

    //
    // Checks if an index exists on disk
    //
    private async indexExistsOnDisk(fieldName: string): Promise<boolean> {
        // If we've already checked this field name, use the cached result
        if (this.loadedIndexFields.has(fieldName)) return true;
        if (this.nonexistentIndexFields.has(fieldName)) return false;

        const indexFilePath = `${this.directory}/index/${fieldName}.dat`;
        const exists = await this.storage.fileExists(indexFilePath);

        // Cache the result
        if (exists) {
            this.loadedIndexFields.add(fieldName);
        } else {
            this.nonexistentIndexFields.add(fieldName);
        }

        return exists;
    }

    //
    // Lazily loads an index if it exists
    //
    private async loadIndexIfExists(fieldName: string): Promise<IBsonIndex<RecordT> | undefined> {
        // Return immediately if the index is already loaded
        let index = this.indexes.get(fieldName);
        if (index) return index;

        // Check if the index file exists
        const exists = await this.indexExistsOnDisk(fieldName);
        if (!exists) return undefined;

        // Create and initialize the index
        index = new BsonIndex<RecordT>({
            storage: this.storage,
            directory: this.directory,
            fieldName: fieldName
        });

        this.indexes.set(fieldName, index);
        console.log(`Lazily loaded index for field '${fieldName}'`);

        return index;
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

        // Shut down all indexes
        for (const index of this.indexes.values()) {
            await index.shutdown();
        }
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
                await this.storage.delete(shardFilePath);
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

        // Ensure all indexes are loaded before making changes
        await this.loadAllIndexes();

        const shardId = this.generateShardId(record._id);
        const shard = await this.loadShard(shardId);

        this.setRecord(record._id, record, shard);

        // Update all indexes
        for (const index of this.indexes.values()) {
            await index.indexRecord(record);
        }

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

        let next: string | undefined = undefined;

        do {
            let result = await this.storage.listFiles(this.directory, 1000, next);
            let files = result.names || [];
            for (const file of files) {
                const shardId = parseInt(file);
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

                const buffer = await this.storage.read(`${this.directory}/${file}`);
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
            next = result.next;
        } while (next);
    }

    //
    // Gets all records in the collection.
    //
    async getAll(skip: number, limit: number): Promise<RecordT[]> {
        const results: RecordT[] = [];

        let count = 0;

        // Use the generator to process records one by one
        for await (const record of this.iterateRecords()) {
            count ++;
            if (count <= skip) {
                continue; //TODO: It's expensive to discard records like this. But having an index might solve this.
            }

            results.push(record);
            if (results.length >= limit) {
                break;
            }
        }

        return results;
    }

    //
    // Updates a record.
    //
    async updateOne(id: string, updates: Partial<RecordT>, options?: { upsert?: boolean }): Promise<boolean> {
        // Ensure all indexes are loaded before making changes
        await this.loadAllIndexes();

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

        // Update all indexes
        for (const index of this.indexes.values()) {
            // Remove old record from index
            if (existingRecord) {
                await index.removeRecord(id);
            }
            // Add updated record to index
            await index.indexRecord(updatedRecord);
        }

        this.scheduleSave(`updated record ${id}`);

        return true;
    }

    //
    // Replaces a record with completely new data.
    //
    async replaceOne(id: string, record: RecordT, options?: { upsert?: boolean }): Promise<boolean> {
        // Ensure all indexes are loaded before making changes
        await this.loadAllIndexes();

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

        // Update all indexes
        for (const index of this.indexes.values()) {
            // Remove old record from index
            if (existingRecord) {
                await index.removeRecord(id);
            }
            // Add new record to index
            await index.indexRecord(record);
        }

        this.scheduleSave(`replaced record ${id}`);

        return true;
    }

    //
    // Deletes a record.
    //
    async deleteOne(id: string): Promise<boolean> {
        // Ensure all indexes are loaded before making changes
        await this.loadAllIndexes();

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

        // Remove from all indexes
        for (const index of this.indexes.values()) {
            await index.removeRecord(id);
        }

        this.scheduleSave(`deleted record ${id}`);

        return true;
    }

    //
    // Creates an index for the given field, but only if it doesn't already exist.
    //
    async ensureIndex(fieldName: string): Promise<IBsonIndex<RecordT>> {
        // Check if the index already exists in memory
        let index = this.indexes.get(fieldName);

        if (index) {
            console.log(`Using existing in-memory index for field '${fieldName}'`);
            return index;
        }

        // Check if the index exists on disk but isn't loaded
        const existsOnDisk = await this.indexExistsOnDisk(fieldName);
        if (existsOnDisk) {
            // Load the existing index
            index = await this.loadIndexIfExists(fieldName);
            if (index) {
                console.log(`Loaded existing index from disk for field '${fieldName}'`);
                return index;
            }
        }

        // Create a new index
        index = new BsonIndex<RecordT>({
            storage: this.storage,
            directory: this.directory,
            fieldName: fieldName
        });

        this.indexes.set(fieldName, index);
        this.loadedIndexFields.add(fieldName);
        this.nonexistentIndexFields.delete(fieldName);

        // If we previously thought all indexes were loaded,
        // we need to reset that since we're adding a new one
        if (this.allIndexesLoaded) {
            this.allIndexesLoaded = true; // Set to true since we know all indexes now
        }

        // Populate the index with existing records
        for await (const record of this.iterateRecords()) {
            await index.indexRecord(record);
        }

        return index;
    }

    //
    // Gets an existing index by field name
    //
    async getIndex(fieldName: string): Promise<IBsonIndex<RecordT> | undefined> {
        // Lazily load the index if it exists but isn't loaded yet
        return await this.loadIndexIfExists(fieldName);
    }

    //
    // Loads all indexes from disk to ensure they're available for record operations
    //
    private async loadAllIndexes(): Promise<void> {
        // If we've already loaded all indexes, just return
        if (this.allIndexesLoaded) {
            return;
        }

        // Check for index files on disk
        const indexDirPath = `${this.directory}/index`;

        // Check if index directory exists
        const dirExists = await this.storage.dirExists(indexDirPath);
        if (!dirExists) {
            // No indexes to load
            this.allIndexesLoaded = true;
            return;
        }

        // List index files
        const result = await this.storage.listFiles(indexDirPath, 1000);
        const indexFiles = result.names || [];

        // Process each index file
        for (const file of indexFiles) {
            if (file === '.placeholder' || !file.endsWith('.dat')) {
                continue; // Skip placeholder files or non-index files
            }

            // Extract field name from file name (remove .dat extension)
            const fieldName = file.substring(0, file.length - 4);

            // If the index is already loaded, skip it
            if (this.indexes.has(fieldName)) {
                continue;
            }

            // Load the index
            await this.loadIndexIfExists(fieldName);
        }

        // Mark all indexes as loaded
        this.allIndexesLoaded = true;
    }

    //
    // List all indexes for this collection (both in memory and on disk)
    //
    async listIndexes(): Promise<string[]> {
        // Start with indexes already loaded in memory
        const indexNames = new Set<string>(this.indexes.keys());

        // Add known index fields (may not be loaded yet)
        for (const fieldName of this.loadedIndexFields) {
            indexNames.add(fieldName);
        }

        // Check for any additional index files on disk
        const indexDirPath = `${this.directory}/index`;

        // Check if index directory exists
        const dirExists = await this.storage.dirExists(indexDirPath);
        if (dirExists) {
            // List index files
            const result = await this.storage.listFiles(indexDirPath, 1000);
            const indexFiles = result.names || [];

            for (const file of indexFiles) {
                if (file === '.placeholder' || !file.endsWith('.dat')) {
                    continue; // Skip placeholder files or non-index files
                }

                // Extract field name from file name (remove .dat extension)
                const fieldName = file.substring(0, file.length - 4);
                indexNames.add(fieldName);

                // Update our cache of known index fields
                this.loadedIndexFields.add(fieldName);
                this.nonexistentIndexFields.delete(fieldName);
            }
        }

        return Array.from(indexNames);
    }

    //
    // Find records by index
    //
    async findByIndex(fieldName: string, value: any): Promise<RecordT[]> {
        // Lazily load the index if it exists
        const index = await this.loadIndexIfExists(fieldName);

        if (!index) {
            throw new Error(`Index for field "${fieldName}" does not exist`);
        }

        // Find record IDs matching the value
        const recordIds = await index.findByValue(value);

        if (recordIds.length === 0) {
            return [];
        }

        // Retrieve the records
        const records: RecordT[] = [];
        for (const recordId of recordIds) {
            const record = await this.getOne(recordId);
            if (record) {
                records.push(record);
            }
        }

        return records;
    }

    //
    // Deletes an index
    //
    async deleteIndex(fieldName: string): Promise<boolean> {
        // Check if index exists in memory
        let index = this.indexes.get(fieldName);

        // If not in memory, check if it exists on disk
        if (!index) {
            const exists = await this.indexExistsOnDisk(fieldName);

            if (!exists) {
                return false; // Index doesn't exist
            }

            // Load the index if it exists on disk
            index = await this.loadIndexIfExists(fieldName);

            if (!index) {
                return false; // Index couldn't be loaded
            }
        }

        // Shut down the index
        await index.shutdown();

        // Remove from the indexes map
        this.indexes.delete(fieldName);

        // Remove from caches
        this.loadedIndexFields.delete(fieldName);
        this.nonexistentIndexFields.add(fieldName);

        // Update the allIndexesLoaded flag if it was set
        if (this.allIndexesLoaded) {
            this.allIndexesLoaded = false;
        }

        // Delete the index file - now located in collection-dir/index/field.dat
        const indexFilePath = `${this.directory}/index/${fieldName}.dat`;
        if (await this.storage.fileExists(indexFilePath)) {
            await this.storage.delete(indexFilePath);
        }

        return true;
    }

    //
    // Drops the whole collection.
    //
    async drop(): Promise<void> {
        this.clearSchedule(); // Clear any pending saves.
        this.shardCache.clear(); // Clear all shards from memory.

        // Shutdown all indexes
        for (const index of this.indexes.values()) {
            await index.shutdown();
        }
        this.indexes.clear();

        // Clear index caches
        this.loadedIndexFields.clear();
        this.nonexistentIndexFields.clear();

        // Delete the index directory
        const indexDirPath = `${this.directory}/index`;
        if (await this.storage.dirExists(indexDirPath)) {
            await this.storage.delete(indexDirPath);
        }

        // Delete the collection directory
        await this.storage.delete(this.directory);
    }
}