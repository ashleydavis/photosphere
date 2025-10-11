//
// A collection in a database that stores BSON records in a sharded format.
//

import crypto from 'crypto';
import { BSON } from 'bson';
import { IStorage } from '../storage';
import { retry, IUuidGenerator } from 'utils';
import { BinarySerializer, BinaryDeserializer } from 'serialization';
import { SortManager } from './sort-manager';
import { IRangeOptions, ISortResult, SortDataType, SortDirection } from './sort-index';

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
    // UUID generator for creating unique identifiers.
    //
    uuidGenerator: IUuidGenerator;

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

export interface IShard<RecordT extends IRecord> {
    id: number;
    records: Map<string, RecordT>;
}

export interface IGetAllResult<RecordT extends IRecord> {
    records: RecordT[];
    next?: string;
}

export interface IBsonCollection<RecordT extends IRecord> {

    //
    // Insert a new record into the collection.
    // Throws an error if a document with the same ID already exists.
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
    // Lists the shard IDs that actually exist as files on disk.
    //
    listExistingShards(): Promise<number[]>;

    //
    // Iterate each shared in the collection without loading all into memory.
    //
    iterateShards(): AsyncGenerator<Iterable<RecordT>, void, unknown>;

    //
    // Gets records from the collection with pagination and continuation support.
    // @param continuation Optional token to continue from a previous query
    // @returns An object containing records from one shard and a continuation token for the next query
    //
    getAll(next?: string): Promise<IGetAllResult<RecordT>>;

    //
    // Get records sorted by a specified field.
    // @param fieldName The field to sort by
    // @param direction The sort direction (asc or desc)
    // @param pageId Optional page ID for pagination
    // @returns Paginated sorted records with metadata
    //
    getSorted(
        fieldName: string,
        direction: SortDirection,
        pageId?: string
    ): Promise<{
        records: RecordT[];
        totalRecords: number;
        currentPageId: string;
        totalPages: number;
        nextPageId?: string;
        previousPageId?: string;
    }>;

    //
    // Create or rebuild a sort index for the specified field
    // @param fieldName The field to create a sort index for
    // @param direction The sort direction
    //
    ensureSortIndex(fieldName: string, direction: SortDirection, type: SortDataType): Promise<void>;

    //
    // Load a sort index from storage.
    //
    loadSortIndex(fieldName: string, direction: SortDirection, type: SortDataType): Promise<void>;

    //
    // List all sort indexes for this collection
    //
    listSortIndexes(): Promise<Array<{
        fieldName: string;
        direction: SortDirection;
    }>>;

    //
    // Delete a sort index
    //
    deleteSortIndex(fieldName: string, direction: SortDirection): Promise<boolean>;

    //
    // Updates a record.
    //
    updateOne(id: string, updates: Partial<RecordT>, options?: { upsert?: boolean }): Promise<boolean>;

    //
    // Replaces a record with completely new data.
    //
    replaceOne(id: string, record: RecordT, options?: { upsert?: boolean }): Promise<boolean>;

    //
    // Deletes a record.
    //
    deleteOne(id: string): Promise<boolean>;

    //
    // Checks if a sort index exists for the given field name
    //
    hasIndex(fieldName: string, direction: SortDirection): Promise<boolean>;

    //
    // List all indexes for this collection
    //
    listIndexes(): Promise<string[]>;

    //
    // Find records by index
    //
    findByIndex(fieldName: string, value: any): Promise<RecordT[]>;
    
    //
    // Find records where the indexed field is within a range
    //
    findByRange(fieldName: string, direction: SortDirection, options: IRangeOptions): Promise<RecordT[]>;
    
    //
    // Deletes an index
    //
    deleteIndex(fieldName: string): Promise<boolean>;

    //
    // Drops the whole collection.
    //
    drop(): Promise<void>;

    //
    // Gets the number of shards in the collection.
    //
    getNumShards(): number;

    //
    // Loads the requested shard from cache or from storage.
    //
    loadShard(shardId: number): Promise<IShard<RecordT>>;    
}

export class BsonCollection<RecordT extends IRecord> implements IBsonCollection<RecordT> {
    private storage: IStorage;
    private directory: string;
    private numShards: number;
    private sortManager: SortManager<RecordT>;

    //
    // UUID generator for creating unique identifiers.
    //
    private readonly uuidGenerator: IUuidGenerator;

    constructor(private readonly name: string, options: IBsonCollectionOptions) {
        this.storage = options.storage;
        this.directory = options.directory;
        this.numShards = options.numShards || 100;
        this.uuidGenerator = options.uuidGenerator;

        this.sortManager = new SortManager({
            storage: this.storage,
            baseDirectory: this.directory.split('/').slice(0, -1).join('/'), // Parent directory
            uuidGenerator: this.uuidGenerator
        }, this, this.name);
    }
    
    //
    // Check the format of uuids.
    //
    private expectValidUuid(id: string): void {
        const uuidRegex = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
        if (!uuidRegex.test(id)) {
            throw new Error(`Invalid UUID format: ${id}`);
        }
    }

    //
    // Put id through a buffer and be sure it's in standarized v4 format.
    //
    private normalizeId(id: string) {
        //TODO: Would like to have this if my data wasn't full of invalid UUIDs.
        // this.expectValidUuid(id);

        const idBuffer = Buffer.from(id.replace(/-/g, ''), "hex");
        if (idBuffer.length !== 16) {
            throw new Error(`Invalid record ID ${id} with length ${idBuffer.length}`);
        }

        return idBuffer.toString("hex");
    }

    //
    // Saves the shard.
    //
    private async saveShard(shard: IShard<any>): Promise<void> {
        const filePath = `${this.directory}/${shard.id}`;
        await this.saveShardFile(filePath, shard);
    }

    //
    // Adds a record to the shard cache.
    //
    private async setRecord(id: string, record: RecordT, shard: IShard<any>): Promise<void> {
        const normalizedId = this.normalizeId(id);
        shard.records.set(normalizedId, record);
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
        const serializer = new BinarySerializer();

        // Write version (4 bytes LE)
        serializer.writeUInt32(1);
        
        // Write record count (4 bytes LE)
        serializer.writeUInt32(shard.records.size);

        // Sort records by ID to ensure deterministic output
        const sortedRecords = Array.from(shard.records.values()).sort((a, b) => a._id.localeCompare(b._id));
        
        for (const record of sortedRecords) {
            const recordIdBuffer = Buffer.from(record._id.replace(/-/g, ''), 'hex');
            if (recordIdBuffer.length !== 16) {
                throw new Error(`Invalid record ID ${record._id} with length ${recordIdBuffer.length}`);
            }
            // Write record ID (16 bytes raw, no length prefix)
            serializer.writeBytes(recordIdBuffer);

            const recordNoId: any = { ...record };
            delete recordNoId._id; // Remove the id, no need to store it twice.
            const recordBson = BSON.serialize(recordNoId);

            // Write record length (4 bytes LE) 
            serializer.writeUInt32(recordBson.length);
            // Write record BSON data (no length prefix since we wrote it manually)
            serializer.writeBytes(Buffer.from(recordBson));
        }

        const allData = serializer.getBuffer();
        const allDataChecksum = this.calculateChecksum(allData);
        if (allDataChecksum.length !== 32) {
            throw new Error(`Checksum length mismatch: ${allDataChecksum.length}`);
        }
        const dataWithChecksum = Buffer.concat([allData, allDataChecksum]);

        //
        // Writes the file.
        //
        await retry(() => this.storage.write(filePath, undefined, dataWithChecksum));

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

        // Read all records from the file
        const fileData = await this.storage.read(shardFilePath);
        if (fileData && fileData.length > 0) {
            const deserializer = new BinaryDeserializer(fileData);

            // Read version (4 bytes LE)
            const version = deserializer.readUInt32();

            // Read record count (4 bytes LE)
            const recordCount = deserializer.readUInt32();

            for (let i = 0; i < recordCount; i++) {
                // Read record ID (16 bytes raw, no length prefix)
                const recordIdBuffer = deserializer.readBytes(16);
                const hexString = recordIdBuffer.toString('hex');
                const recordId = [
                    hexString.substring(0, 8),
                    hexString.substring(8, 12),
                    hexString.substring(12, 16),
                    hexString.substring(16, 20),
                    hexString.substring(20)
                ].join('-');

                // Read record length (4 bytes LE)
                const recordLength = deserializer.readUInt32();

                // Read record BSON data (no length prefix since we read length manually)
                const recordData = deserializer.readBytes(recordLength);
                const record = BSON.deserialize(recordData) as RecordT;
                record._id = recordId;
                records.push(record);
            }
        }

        return records;
    }

    //
    // Gets the number of shards in the collection.
    //
    getNumShards(): number {
        return this.numShards;
    }

    //
    // Loads the requested shard from cache or from storage.
    //
    async loadShard(shardId: number): Promise<IShard<RecordT>> {
        const filePath = `${this.directory}/${shardId}`;
        const records = await this.loadRecords(filePath);
        let shard = {
            id: shardId,
            records: new Map<string, RecordT>(),
        };

        for (const record of records) {
            await this.setRecord(record._id, record, shard);
        }

        return shard;
    }

    //
    // Insert a new record into the collection.
    // Throws an error if a document with the same ID already exists.
    //
    async insertOne(record: RecordT): Promise<void> {
        if (!record._id) {
            record._id = this.uuidGenerator.generate();
        }

        const shardId = this.generateShardId(record._id);
        const shard = await this.loadShard(shardId);

        if (this.getRecord(record._id, shard)) {
            throw new Error(`Document with ID ${record._id} already exists in shard ${shardId}`);
        }

        await this.setRecord(record._id, record, shard);
        await this.saveShard(shard);

        await this.sortManager.addRecord(record);
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

        return record;
    }

    //
    // Iterate all records in the collection without loading all into memory.
    //
    async *iterateRecords(): AsyncGenerator<RecordT, void, unknown> {

        for (let shardId = 0; shardId < this.numShards; shardId++) {
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
    // Lists the shard IDs that actually exist as files on disk.
    //
    async listExistingShards(): Promise<number[]> {
        const shardIds: number[] = [];
        
        for (let shardId = 0; shardId < this.numShards; shardId++) {
            const filePath = `${this.directory}/${shardId}`;
            const exists = await this.storage.fileExists(filePath);
            if (exists) {
                shardIds.push(shardId);
            }
        }
        
        return shardIds;
    }

    //
    // Iterate each shard in the collection without loading all into memory.
    //
    async *iterateShards(): AsyncGenerator<Iterable<RecordT>, void, unknown> {
        for (let shardId = 0; shardId < this.numShards; shardId++) {
            const buffer = await this.storage.read(`${this.directory}/${shardId}`);
            if (!buffer || buffer.length === 0) {
                continue;
            }

            const version = buffer.readUInt32LE(0); // Version
            const recordCount = buffer.readUInt32LE(4); // Record count

            let offset = 8; // Skip the version and record count.

            const records: RecordT[] = [];
            for (let i = 0; i < recordCount; i++) {
                const { record, offset: newOffset } = this.readRecord(buffer, offset);
                records.push(record);
                offset = newOffset;
            }
            yield records;
        }
    }

    //
    // Gets records from the collection with pagination and continuation support.
    // @param next Optional token to continue from a previous query
    // @returns An object containing records from one shard and a continuation token for the next query
    //
    async getAll(next?: string): Promise<IGetAllResult<RecordT>> {

        let shardId = next ? parseInt(next) : 0;
        while (shardId < this.numShards) {
            // Load records from storage
            const filePath = `${this.directory}/${shardId}`;
            const records = await this.loadRecords(filePath);
            if (records.length > 0) {
                return { records, next: `${shardId + 1}` };
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
        await this.setRecord(id, updatedRecord, shard);
        await this.saveShard(shard);

        await this.sortManager.updateRecord(updatedRecord, existingRecord);

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
        await this.setRecord(id, record, shard);
        await this.saveShard(shard);

        await this.sortManager.updateRecord(record, existingRecord);

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
        await this.saveShard(shard);

        await this.sortManager.deleteRecord(id, existingRecord);

        return true;
    }   

    //
    // Checks if a sort index exists for the given field name
    //
    async hasIndex(fieldName: string, direction: SortDirection): Promise<boolean> {
        return await this.sortManager.hasSortIndex(fieldName, direction);
    }
        
    //
    // List all sort indexes for this collection
    //
    async listIndexes(): Promise<string[]> {
        // Get all sort indexes and extract field names
        const fieldNames = new Set<string>();
        
        const sortIndexes = await this.sortManager.listSortIndexes();
        
        // Add field names from sort indexes
        for (const index of sortIndexes) {
            fieldNames.add(index.fieldName);
        }
        
        return Array.from(fieldNames);
    }

    //
    // Find records by index using SortIndex
    //
    async findByIndex(fieldName: string, value: any): Promise<RecordT[]> {
       
        // Try to find an existing sort index for the field (check both asc and desc)
        const ascIndex = await this.sortManager.getSortIndex(fieldName, 'asc');
        if (ascIndex) {
            // Use the sort index for faster search with binary search
            return await ascIndex.findByValue(value);
        }
        
        const descIndex = await this.sortManager.getSortIndex(fieldName, 'desc');
        if (descIndex) {
            // Use the sort index for faster search with binary search
            return await descIndex.findByValue(value);
        }
        
        throw new Error(`No sort index found for field "${fieldName}" in either direction`);
    }
    
    //
    // Find records where the indexed field is within a range
    //
    async findByRange(fieldName: string, direction: SortDirection, options: IRangeOptions): Promise<RecordT[]> {
        const sortIndex = await this.sortManager.getSortIndex(fieldName, direction);
        if (!sortIndex) {
            throw new Error(`Failed to create sort index for field '${fieldName}'`);
        }
        
        return await sortIndex.findByRange(options);
    }
    
    //
    // Deletes all indexes for a field (both asc and desc)
    //
    async deleteIndex(fieldName: string): Promise<boolean> {
        const deleteAsc = await this.sortManager.deleteSortIndex(fieldName, 'asc');
        const deleteDesc = await this.sortManager.deleteSortIndex(fieldName, 'desc');
        return deleteAsc || deleteDesc;
    }
    
    //
    // Get records sorted by a specified field
    //
    async getSorted(fieldName: string, direction: SortDirection, pageId?: string): Promise<ISortResult<RecordT>> {
        return await this.sortManager.getSortedRecords(fieldName, direction, pageId);
    }

    //
    // Create or rebuild a sort index for the specified field
    //
    async ensureSortIndex(fieldName: string, direction: SortDirection, type: SortDataType): Promise<void> {       
        await this.sortManager.ensureSortIndex(fieldName, direction, type);
    }

    //
    // Load a sort index from storage.
    //
    async loadSortIndex(fieldName: string, direction: SortDirection, type: SortDataType): Promise<void> {
        await this.sortManager.loadSortIndex(fieldName, direction, type);
    }

    //
    // List all sort indexes for this collection
    //
    async listSortIndexes(): Promise<Array<{ fieldName: string; direction: SortDirection; }>> {              
        return await this.sortManager.listSortIndexes();
    }

    //
    // Delete a sort index
    //
    async deleteSortIndex(fieldName: string, direction: SortDirection): Promise<boolean> {        
        return await this.sortManager.deleteSortIndex(fieldName, direction);
    }

    //
    // Drops the whole collection.
    //
    async drop(): Promise<void> {       
        // Delete sort indexes if any
        await this.sortManager.deleteAllSortIndexes();
        
        // Delete the index directory
        const indexDirPath = `${this.directory}/index`;
        if (await this.storage.dirExists(indexDirPath)) {
            await this.storage.deleteFile(indexDirPath);
        }
        
        // Delete the collection directory
        await this.storage.deleteDir(this.directory); 
    }
}