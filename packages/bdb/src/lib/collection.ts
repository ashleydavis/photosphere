//
// A collection in a database that stores BSON records in a sharded format.
//

import crypto from 'crypto';
import type { IStorage } from 'storage';
import type { IUuidGenerator, ITimestampProvider } from 'utils';
import { save, load, BinaryDeserializer } from 'serialization';
import type { ISerializer, IDeserializer } from 'serialization';
import { SortManager } from './sort-manager';
import type { IRangeOptions, SortDataType, SortDirection } from './sort-index';
import { updateMetadata } from './update-metadata';
import { updateFields } from './update-fields';

export interface ISortResult<RecordT extends IRecord> {
    // Records for the requested page
    records: RecordT[];

    // Total number of records in the collection
    totalRecords: number;
    
    // Current page ID
    currentPageId: string;
    
    // Total number of leaf pages (navigable data pages)
    totalPages: number;
    
    // Next page ID or undefined if this is the last page
    nextPageId?: string;
    
    // Previous page ID or undefined if this is the first page
    previousPageId?: string;
}

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
    // Timestamp provider for generating timestamps.
    //
    timestampProvider: ITimestampProvider;

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

//
// Records the metadata for a primitive value.
//
export type Metadata = {
    // Timestamp that shows the last time the value was modified.
    timestamp?: number; 

    // Metadata for nested fields.
    fields?: {
        [key: string]: Metadata;
    }
}

//
// Internal record structure with fields separated into a subobject.
// Used internally for storage, but converted to/from IRecord at API boundaries.
//
export interface IInternalRecord {
    // The record ID.
    _id: string;

    // The record fields.
    fields: {
        [key: string]: any;
    };

    // The metadata for the record.
    metadata: Metadata;
}

//
// Convert external IRecord to internal IInternalRecord format
//
export function toInternal<RecordT extends IRecord>(record: RecordT, timestamp?: number): IInternalRecord {
    const { _id, ...fields } = record;
    
    // Initialize metadata as ObjectMetadata (records have no timestamp)
    const internal: IInternalRecord = {
        _id,
        fields,
        metadata: {
            timestamp,
        },
    };

    return internal;
}

//
// Convert internal IInternalRecord to external IRecord format
//
export function toExternal<RecordT extends IRecord>(internal: IInternalRecord): RecordT {
    return {
        _id: internal._id,
        ...internal.fields
    } as RecordT;
}

//
// Internal shard - stores records in internal format
//
export interface IShard {
    id: number;
    records: Map<string, IInternalRecord>;
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
    insertOne(record: RecordT, options?: { timestamp?: number }): Promise<void>;

    //
    // Gets one record by ID.
    //
    getOne(id: string): Promise<RecordT | undefined>;

    //
    // Iterate all records in the collection without loading all into memory.
    //
    iterateRecords(): AsyncGenerator<IInternalRecord, void, unknown>;

    //
    // Lists the shard IDs that actually exist as files on disk.
    //
    listExistingShards(): Promise<number[]>;

    //
    // Iterate each shared in the collection without loading all into memory.
    //
    iterateShards(): AsyncGenerator<Iterable<IInternalRecord>, void, unknown>;

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
    // @param timestamp Optional unix timestamp for field metadata (defaults to current time)
    //
    updateOne(id: string, updates: Partial<RecordT>, options?: { upsert?: boolean; timestamp?: number }): Promise<boolean>;

    //
    // Replaces a record with completely new data.
    // @param timestamp Optional unix timestamp for field metadata (defaults to current time)
    //
    replaceOne(id: string, record: RecordT, options?: { upsert?: boolean; timestamp?: number }): Promise<boolean>;

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
    loadShard(shardId: number): Promise<IShard>;    
}

export class BsonCollection<RecordT extends IRecord> implements IBsonCollection<RecordT> {
    private storage: IStorage;
    private directory: string;
    private numShards: number;
    private sortManager: SortManager;

    //
    // UUID generator for creating unique identifiers.
    //
    private readonly uuidGenerator: IUuidGenerator;

    //
    // Timestamp provider for generating timestamps.
    //
    private readonly timestampProvider: ITimestampProvider;

    //
    // Current version for shard file format
    //
    private static readonly SHARD_FILE_VERSION = 2;

    constructor(private readonly name: string, options: IBsonCollectionOptions) {
        this.storage = options.storage;
        this.directory = options.directory;
        this.numShards = options.numShards || 100;
        this.uuidGenerator = options.uuidGenerator;
        this.timestampProvider = options.timestampProvider;

        this.sortManager = new SortManager({
            storage: this.storage,
            baseDirectory: this.directory.split('/').slice(0, -1).join('/'), // Parent directory
            uuidGenerator: this.uuidGenerator
        }, this.name);
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
    private async saveShard(shard: IShard): Promise<void> {
        const filePath = `${this.directory}/${shard.id}`;
        await this.saveShardFile(filePath, shard);
    }

    //
    // Adds a record to the shard cache.
    //
    private async setRecord(id: string, record: IInternalRecord, shard: IShard): Promise<void> {
        const normalizedId = this.normalizeId(id);
        shard.records.set(normalizedId, record);
    }

    //
    // Gets a record from the shard cache.
    //
    private getRecord(id: string, shard: IShard): IInternalRecord | undefined {
        const normalizedId = this.normalizeId(id);
        return shard.records.get(normalizedId);
    }

    //
    // Deletes a record from the shard cache.
    //
    private deleteRecord(id: string, shard: IShard): void {
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
    // Saves the shard file to storage.
    //
    private async saveShardFile(shardFilePath: string, shard: IShard): Promise<void> {
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
    // Serializes a single record to the serializer
    //
    private serializeRecord(record: IInternalRecord, serializer: ISerializer): void {
        const recordIdBuffer = Buffer.from(record._id.replace(/-/g, ''), 'hex');
        if (recordIdBuffer.length !== 16) {
            throw new Error(`Invalid record ID ${record._id} with length ${recordIdBuffer.length}`);
        }
        // Write record ID (16 bytes raw, no length prefix)
        serializer.writeBytes(recordIdBuffer);

        // Write the fields (not _id) - record is already in internal format
        serializer.writeBSON(record.fields);
        
        // Write metadata (version 2+)
        serializer.writeBSON(record.metadata);
    }

    //
    // Writes a shard to disk.
    //
    private serializeShard(shard: IShard, serializer: ISerializer): void {
        // Write record count (4 bytes LE)
        serializer.writeUInt32(shard.records.size);

        // Sort records by ID to ensure deterministic output
        const sortedRecords = Array.from(shard.records.values()).sort((a, b) => a._id.localeCompare(b._id));
        
        for (const record of sortedRecords) {
            this.serializeRecord(record, serializer);
        }
    }

    private async writeBsonFile(filePath: string, shard: IShard): Promise<void> {
        await save(
            this.storage,
            filePath,
            shard,
            BsonCollection.SHARD_FILE_VERSION,
            (shardData, serializer) => this.serializeShard(shardData, serializer)
        );
    }

    //
    // Deserializes a version 1 record (fields only, no metadata)
    //
    private deserializeRecordV1(deserializer: IDeserializer): IInternalRecord {
        // Read 16 byte uuid
        const recordIdBuffer = deserializer.readBytes(16);
        const hexString = recordIdBuffer.toString('hex');
        const recordId = [
            hexString.substring(0, 8),
            hexString.substring(8, 12),
            hexString.substring(12, 16),
            hexString.substring(16, 20),
            hexString.substring(20)
        ].join('-');

        // Read and deserialize the record fields
        const fields = deserializer.readBSON<any>();
        
        return { 
            _id: recordId,
            fields,
            metadata: {},
        };
    }

    //
    // Deserializes a version 2 record (fields and metadata)
    //
    private deserializeRecordV2(deserializer: IDeserializer): IInternalRecord {
        // Read 16 byte uuid
        const recordIdBuffer = deserializer.readBytes(16);
        const hexString = recordIdBuffer.toString('hex');
        const recordId = [
            hexString.substring(0, 8),
            hexString.substring(8, 12),
            hexString.substring(12, 16),
            hexString.substring(16, 20),
            hexString.substring(20)
        ].join('-');

        // Read and deserialize the record fields
        const fields = deserializer.readBSON<any>();

        // Read and deserialize metadata
        const metadata = deserializer.readBSON<Metadata>();
        
        return { 
            _id: recordId,
            fields,
            metadata,
        };
    }

    //
    // Deserializes a single record from the deserializer.
    // Delegates to version-specific deserialization functions.
    //
    private deserializeRecord(deserializer: IDeserializer, fileVersion: number): IInternalRecord {
        if (fileVersion === 2) {
            return this.deserializeRecordV2(deserializer);
        } else if (fileVersion === 1) {
            return this.deserializeRecordV1(deserializer);
        } else {
            throw new Error(`Invalid file version: ${fileVersion}`);
        }
    }

    //
    // Migrates old flat format to new format with fields subobject
    // Deserializer function for version 1 shard data
    //
    private deserializeShardV1(deserializer: IDeserializer): IInternalRecord[] {
        const records: IInternalRecord[] = [];

        // Read record count (4 bytes LE)
        const recordCount = deserializer.readUInt32();

        for (let i = 0; i < recordCount; i++) {
            records.push(this.deserializeRecordV1(deserializer));
        }

        return records;
    }

    //
    // Deserializer function for version 2 shard data
    // Returns records in internal format.
    //
    private deserializeShardV2(deserializer: IDeserializer): IInternalRecord[] {
        const records: IInternalRecord[] = [];

        // Read record count (4 bytes LE)
        const recordCount = deserializer.readUInt32();

        for (let i = 0; i < recordCount; i++) {
            records.push(this.deserializeRecordV2(deserializer));
        }

        return records;
    }

    //
    // Loads all records from a shard file.
    // Supports version 1 and 2.
    // Returns records in internal format.
    //
    private async loadRecords(shardFilePath: string): Promise<IInternalRecord[]> {
        const records = await load<IInternalRecord[]>(
            this.storage,
            shardFilePath,
            {
                1: (deserializer) => this.deserializeShardV1(deserializer),
                2: (deserializer) => this.deserializeShardV2(deserializer)
            }
        );
        
        // Return empty array if file doesn't exist (load returns undefined)
        return records || [];
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
    async loadShard(shardId: number): Promise<IShard> {
        const filePath = `${this.directory}/${shardId}`;
        const records = await this.loadRecords(filePath);
        const shard: IShard = {
            id: shardId,
            records: new Map<string, IInternalRecord>(),
        };

        for (const record of records) {
            const normalizedId = this.normalizeId(record._id);
            shard.records.set(normalizedId, record);
        }

        return shard;
    }

    //
    // Insert a new record into the collection.
    // Throws an error if a document with the same ID already exists.
    //
    async insertOne(record: RecordT, options?: { timestamp?: number }): Promise<void> {
        if (!record._id) {
            record._id = this.uuidGenerator.generate();
        }

        const shardId = this.generateShardId(record._id);
        const shard = await this.loadShard(shardId);

        if (this.getRecord(record._id, shard)) {
            throw new Error(`Document with ID ${record._id} already exists in shard ${shardId}`);
        }

        // Use provided timestamp or current time
        const versionTimestamp = options?.timestamp ?? this.timestampProvider.now();
        const internalRecord = toInternal<RecordT>(record, versionTimestamp);
        await this.setRecord(record._id, internalRecord, shard);
        await this.saveShard(shard);

        await this.sortManager.addRecord(internalRecord);
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

        return toExternal<RecordT>(record);
    }

    //
    // Iterate all records in the collection without loading all into memory.
    //
    async *iterateRecords(): AsyncGenerator<IInternalRecord, void, unknown> {

        for (let shardId = 0; shardId < this.numShards; shardId++) {
             const buffer = await this.storage.read(`${this.directory}/${shardId}`);
             if (!buffer || buffer.length === 0) {
                 continue;
             }

            const deserializer = new BinaryDeserializer(buffer);
            const fileVersion = deserializer.readUInt32(); // Version
            const recordCount = deserializer.readUInt32(); // Record count

            for (let i = 0; i < recordCount; i++) {
                const record = this.deserializeRecord(deserializer, fileVersion);
                yield record;
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
    async *iterateShards(): AsyncGenerator<Iterable<IInternalRecord>, void, unknown> {
        for (let shardId = 0; shardId < this.numShards; shardId++) {
            const buffer = await this.storage.read(`${this.directory}/${shardId}`);
            if (!buffer || buffer.length === 0) {
                continue;
            }

            const deserializer = new BinaryDeserializer(buffer);
            const fileVersion = deserializer.readUInt32(); // Version
            const recordCount = deserializer.readUInt32(); // Record count

            const records: IInternalRecord[] = [];
            for (let i = 0; i < recordCount; i++) {
                const record = this.deserializeRecord(deserializer, fileVersion);
                records.push(record);
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
            const internalRecords = await this.loadRecords(filePath);
            if (internalRecords.length > 0) {
                // Convert to external format
                const records = internalRecords.map(internal => toExternal<RecordT>(internal));
                return { records, next: `${shardId + 1}` };
            }

            shardId += 1;
        }

        return { records: [], next: undefined }; // No more records
    }

    //
    // Updates a record.
    //
    async updateOne(id: string, updates: Partial<Omit<RecordT, '_id'>>, options?: { upsert?: boolean; timestamp?: number }): Promise<boolean> {
        const shardId = this.generateShardId(id);
        const shard = await this.loadShard(shardId);

        let existingRecord = this.getRecord(id, shard);

        if (!options?.upsert) {
            //
            // If not upserting, the record must exist.
            //            
            if (!existingRecord) {
                return false; // Record not found.
            }
        }

        if (!existingRecord) {
            // Creating new record via upsert.
            existingRecord = {
                _id: id,
                fields: {},
                metadata: {}
            };
        }

        //
        // Updates the record fields.
        //

        const timestamp = options?.timestamp ?? this.timestampProvider.now();        
        const updatedRecord: IInternalRecord = {
            _id: id,
            fields: updateFields(existingRecord.fields, updates),
            metadata: updateMetadata(existingRecord.fields, updates, existingRecord.metadata, timestamp),
        };

        await this.setRecord(id, updatedRecord, shard);
        await this.saveShard(shard);

        await this.sortManager.updateRecord(updatedRecord, existingRecord);

        return true;
    }

    //
    // Replaces a record with completely new data.
    //
    async replaceOne(id: string, record: RecordT, options?: { upsert?: boolean; timestamp?: number }): Promise<boolean> {
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
        const versionTimestamp = options?.timestamp ?? Date.now();
        const internalRecord = toInternal<RecordT>(record, versionTimestamp);
        await this.setRecord(id, internalRecord, shard);
        await this.saveShard(shard);

        await this.sortManager.updateRecord(internalRecord, existingRecord);

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
            return (await ascIndex.findByValue(value)).map(sortIndexEntry => ({
                _id: sortIndexEntry._id,
                ...sortIndexEntry.fields
            } as RecordT));
        }
        
        const descIndex = await this.sortManager.getSortIndex(fieldName, 'desc');
        if (descIndex) {
            // Use the sort index for faster search with binary search
            return (await descIndex.findByValue(value)).map(sortIndexEntry => ({
                _id: sortIndexEntry._id,
                ...sortIndexEntry.fields
            } as RecordT));
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
        
        return (await sortIndex.findByRange(options)).map(sortIndexEntry => ({
            _id: sortIndexEntry._id,
            ...sortIndexEntry.fields
        } as RecordT));
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
        const sortedRecords = await this.sortManager.getSortedRecords(fieldName, direction, pageId);
        return {
            records: sortedRecords.records.map(sortEntry => ({
                _id: sortEntry._id,
                ...sortEntry.fields
            }) as RecordT),
            totalRecords: sortedRecords.totalRecords,
            currentPageId: sortedRecords.currentPageId,
            totalPages: sortedRecords.totalPages,
            nextPageId: sortedRecords.nextPageId,
            previousPageId: sortedRecords.previousPageId
        };
    }

    //
    // Create or rebuild a sort index for the specified field
    //
    async ensureSortIndex(fieldName: string, direction: SortDirection, type: SortDataType): Promise<void> {       
        await this.sortManager.ensureSortIndex(fieldName, direction, type, this);
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