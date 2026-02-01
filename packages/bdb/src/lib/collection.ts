//
// A collection in a database that stores BSON records in a sharded format.
//

import type { IStorage } from 'storage';
import type { IUuidGenerator, ITimestampProvider } from 'utils';
import { save, load } from 'serialization';
import type { ISerializer, IDeserializer } from 'serialization';
import { SortIndex } from './sort-index';
import type { IRangeOptions, SortDataType, SortDirection, ISortIndexResult } from './sort-index';
import { updateMetadata } from './update-metadata';
import { updateFields } from './update-fields';
import {
    buildShardMerkleTree,
    saveShardMerkleTree,
    loadShardMerkleTree,
    buildCollectionMerkleTree,
    saveCollectionMerkleTree,
    loadCollectionMerkleTree,
    buildDatabaseMerkleTree,
    loadDatabaseMerkleTree,
    saveDatabaseMerkleTree,
    hashRecord,
    deleteCollectionMerkleTree,
    deleteDatabaseMerkleTree,
    deleteShardMerkleTree,
} from './merkle-tree';
import { deleteItem, upsertItem, IMerkleTree } from 'merkle-tree';
import * as crypto from 'crypto';
import path from 'path';

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
    // The directory where the collection is stored (v6: collections/<name>).
    //
    directory: string;

    //
    // BSON database root (v6: "" = storage root; used for indexes path).
    //
    baseDirectory: string;

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
    id: string;
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
    // @param progressCallback Optional callback to report progress during build (called every 1000 records)
    //
    ensureSortIndex(fieldName: string, direction: SortDirection, type: SortDataType, progressCallback?: (message: string) => void): Promise<void>;


    //
    // Load a sort index from storage.
    //
    loadSortIndexFromStorage(fieldName: string, direction: SortDirection, type: SortDataType): Promise<void>;

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
    // Loads a sort index by field name and direction.
    // Returns the SortIndex instance if it exists, undefined otherwise.
    //
    loadSortIndex(fieldName: string, direction: SortDirection): Promise<SortIndex | undefined>;

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
    // Sets an internal record directly, preserving all timestamps and metadata.
    // This is useful for sync operations where timestamps must be preserved exactly.
    // Always upserts (creates if doesn't exist, updates if it does).
    // @param record The internal record to save (with all metadata intact)
    //
    setInternalRecord(record: IInternalRecord): Promise<void>;

    //
    // Deletes a record.
    //
    deleteOne(id: string): Promise<boolean>;

    //
    // Checks if a sort index exists for the given field name
    //
    hasIndex(fieldName: string, direction: SortDirection): Promise<boolean>;

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
    loadShard(shardId: string): Promise<IShard>;    
}

export class BsonCollection<RecordT extends IRecord> implements IBsonCollection<RecordT> {
    private storage: IStorage;
    private directory: string;

    private readonly baseDirectory: string;
    private numShards: number;
    private readonly defaultPageSize: number = 1000;

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
        this.baseDirectory = options.baseDirectory;
        this.numShards = options.numShards || 100;
        this.uuidGenerator = options.uuidGenerator;
        this.timestampProvider = options.timestampProvider;
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
    // Gets the base directory for sort indexes (v6: BSON root = indexes/).
    //
    private getSortIndexBaseDirectory(): string {
        return this.baseDirectory;
    }

    //
    // Creates a sort index instance.
    //
    private createSortIndex(fieldName: string, direction: SortDirection, type?: SortDataType, pageSize?: number): SortIndex {
        return new SortIndex({
            storage: this.storage,
            baseDirectory: this.getSortIndexBaseDirectory(),
            collectionName: this.name,
            fieldName,
            direction,
            uuidGenerator: this.uuidGenerator,
            pageSize: pageSize || this.defaultPageSize,
            type
        });
    }

    //
    // Loads a sort index by field name and direction.
    // Creates a new instance and tries to load it from disk.
    //
    async loadSortIndex(fieldName: string, direction: SortDirection): Promise<SortIndex | undefined> {
        const sortIndex = this.createSortIndex(fieldName, direction);
        const loaded = await sortIndex.load();
        if (!loaded) {
            return undefined;
        }
        return sortIndex;
    }

    //
    // Adds a record to all sort indexes for this collection.
    //
    private async addRecordToSortIndexes(record: IInternalRecord): Promise<void> {
        const indexes = await this.listSortIndexes();
        for (const indexInfo of indexes) {
            const sortIndex = this.createSortIndex(indexInfo.fieldName, indexInfo.direction);
            const loaded = await sortIndex.load();
            if (loaded) {
                await sortIndex.addRecord(record);
            }
        }
    }

    //
    // Updates a record in all sort indexes.
    //
    private async updateRecordInSortIndexes(updatedRecord: IInternalRecord, oldRecord: IInternalRecord | undefined): Promise<void> {
        const indexes = await this.listSortIndexes();
        for (const indexInfo of indexes) {
            const sortIndex = this.createSortIndex(indexInfo.fieldName, indexInfo.direction);
            const loaded = await sortIndex.load();
            if (loaded) {
                await sortIndex.updateRecord(updatedRecord, oldRecord);
            }
        }
    }

    //
    // Deletes a record from all existing sort indexes.
    //
    private async deleteRecordFromSortIndexes(recordId: string, record: IInternalRecord): Promise<void> {
        const indexes = await this.listSortIndexes();
        for (const indexInfo of indexes) {
            const sortIndex = this.createSortIndex(indexInfo.fieldName, indexInfo.direction);
            const loaded = await sortIndex.load();
            if (loaded) {
                await sortIndex.deleteRecord(recordId, record);
            }
        }
    }

    //
    // Saves the shard.
    //
    private async saveShard(shard: IShard): Promise<void> {
        const filePath = `${this.directory}/shards/${shard.id}`;
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
    private generateShardId(recordId: string): string {
        const recordIdBuffer = Buffer.from(recordId.replace(/-/g, ''), 'hex');
        if (recordIdBuffer.length !== 16) {
            throw new Error(`Invalid record ID ${recordId} with length ${recordIdBuffer.length}`);
        }

        const hash = crypto.createHash('md5').update(recordIdBuffer).digest('hex');
        const decimal = parseInt(hash.substring(0, 8), 16);
        return (decimal % this.numShards).toString();
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
    // Upserts a record in the shard merkle tree (adds if doesn't exist, updates if it does).
    //
    private async upsertRecordInShardTree(shardId: string, record: IInternalRecord, shard: IShard): Promise<void> {
        let shardTree = await loadShardMerkleTree(this.storage, this.directory, shardId);        
        if (!shardTree) {
            // Tree doesn't exist, build it from the shard.
            const records = Array.from(shard.records.values());
            shardTree = await buildShardMerkleTree(records, this.uuidGenerator);
        }
        else {
            // Upsert the record hash in the existing tree (adds if doesn't exist, updates if it does)
            shardTree = upsertItem(shardTree, hashRecord(record));
        }
        
        await saveShardMerkleTree(this.storage, this.directory, shardId, shardTree);        
        await this.updateCollectionTree(shardId, shardTree);
    }

    //
    // Updates the shard merkle tree by deleting a record hash.
    //
    private async deleteRecordFromShardTree(shardId: string, recordId: string, shard: IShard): Promise<void> {

        let shardTree = await loadShardMerkleTree(this.storage, this.directory, shardId);        
        if (!shardTree) {
            // Tree doesn't exist, but if shard still has records, build it.
            const records = Array.from(shard.records.values());
            if (records.length > 0) {
                // Only bother building it if we have more than one record.
                shardTree = await buildShardMerkleTree(records, this.uuidGenerator);
            }
        }

        if (shardTree && shardTree.sort) {
            // Delete the record hash from the tree.
            deleteItem(shardTree, recordId);
        }

        if (!shardTree || !shardTree.sort) {
            // Shard tree is empty, delete it.
            shardTree = undefined;
            await deleteShardMerkleTree(this.storage, this.directory, shardId);
        }
        else {
            await saveShardMerkleTree(this.storage, this.directory, shardId, shardTree);
        }
        
        await this.updateCollectionTree(shardId, shardTree);
    }

    //
    // Updates the collection merkle tree with the updated shard hash.
    //
    private async updateCollectionTree(shardId: string, shardTree: IMerkleTree<undefined> | undefined): Promise<void> {
        
        let collectionTree = await loadCollectionMerkleTree(this.storage, this.directory);        
        if (!collectionTree) {
            // Collection tree doesn't exist, build it.
            collectionTree = await buildCollectionMerkleTree(this.storage, this.name, this.directory, this.uuidGenerator, false);
        }

        if (shardTree && shardTree.merkle) {
            // Update the shard hash in the collection tree.
            const hashedItem = {
                name: shardId.toString(),
                hash: shardTree.merkle.hash,
                length: shardTree.merkle.nodeCount,
                lastModified: new Date(),
            };
            
            collectionTree = upsertItem(collectionTree, hashedItem);
        } 
        else {
            // Shard tree is empty or missing, remove shard from collection tree.
            deleteItem(collectionTree, shardId.toString());
        }

        if (!collectionTree.sort) {
            // Collection tree is empty, delete it.
            collectionTree = undefined;
            await deleteCollectionMerkleTree(this.storage, this.directory);
        }        
        else {
            await saveCollectionMerkleTree(this.storage, this.directory, collectionTree);
        }
        
        await this.updateDatabaseTree(collectionTree);
    }

    //
    // Updates the database merkle tree with the updated collection hash.
    //
    private async updateDatabaseTree(collectionTree: IMerkleTree<undefined> | undefined): Promise<void> {
        
        let databaseTree = await loadDatabaseMerkleTree(this.storage);        
        if (!databaseTree) {
            // Database tree doesn't exist, rebuild it from all collections.
            databaseTree = await buildDatabaseMerkleTree(
                this.storage,
                this.uuidGenerator,
                path.dirname(this.directory),
                this.name,
                collectionTree,
                false
            );            
        }

        // Update the collection hash in the database tree.
        if (collectionTree && collectionTree.merkle) {
            const hashedItem = {
                name: this.name,
                hash: collectionTree.merkle.hash,
                length: collectionTree.merkle.nodeCount,
                lastModified: new Date(),
            };
            databaseTree = upsertItem(databaseTree, hashedItem);
        } 
        else {
            // Collection tree is empty or missing, remove collection from database tree.
            deleteItem(databaseTree, this.name);
        }

        if (!databaseTree.sort) {
            // Database tree is empty, delete it.
            await deleteDatabaseMerkleTree(this.storage);
        }
        else {
            await saveDatabaseMerkleTree(this.storage, databaseTree);
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
            'SHAR',
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
    async loadRecords(shardFilePath: string): Promise<IInternalRecord[]> {
        const records = await load<IInternalRecord[]>(
            this.storage,
            shardFilePath,
            'SHAR',
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
    async loadShard(shardId: string): Promise<IShard> {
        const filePath = `${this.directory}/shards/${shardId}`;
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

        await this.addRecordToSortIndexes(internalRecord);
        
        // Update merkle trees
        await this.upsertRecordInShardTree(shardId, internalRecord, shard);
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
            const records = await this.loadRecords(`${this.directory}/shards/${shardId}`);
            for (const record of records) {
                yield record;
            }
        }
    }

    //
    // Iterate each shard in the collection without loading all into memory.
    // Yields only shards that have records (same as when reading versioned files directly).
    //
    async *iterateShards(): AsyncGenerator<Iterable<IInternalRecord>, void, unknown> {
        for (let shardId = 0; shardId < this.numShards; shardId++) {
            const records = await this.loadRecords(`${this.directory}/shards/${shardId}`);
            if (records.length > 0) {
                yield records;
            }
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
            const filePath = `${this.directory}/shards/${shardId}`;
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

        await this.updateRecordInSortIndexes(updatedRecord, existingRecord);

        //
        // Update merkle trees.
        //
        await this.upsertRecordInShardTree(shardId, updatedRecord, shard);

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

        await this.updateRecordInSortIndexes(internalRecord, existingRecord);

        //
        // Update merkle trees.
        //
        await this.upsertRecordInShardTree(shardId, internalRecord, shard);

        return true;
    }

    //
    // Sets an internal record directly, preserving all timestamps and metadata.
    // This is useful for sync operations where timestamps must be preserved exactly.
    // Always upserts (creates if doesn't exist, updates if it does).
    //
    async setInternalRecord(record: IInternalRecord): Promise<void> {
        const shardId = this.generateShardId(record._id);
        const shard = await this.loadShard(shardId);

        const existingRecord = this.getRecord(record._id, shard);

        // Set the record directly with all its metadata preserved
        await this.setRecord(record._id, record, shard);
        await this.saveShard(shard);

        await this.updateRecordInSortIndexes(record, existingRecord);
        await this.upsertRecordInShardTree(shardId, record, shard);
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

        await this.deleteRecordFromSortIndexes(id, existingRecord);

        // Update merkle trees
        await this.deleteRecordFromShardTree(shardId, id, shard);

        return true;
    }   

    //
    // Checks if a sort index exists for the given field name
    //
    async hasIndex(fieldName: string, direction: SortDirection): Promise<boolean> {
        // Check if the index exists on disk (v6: indexes/).
        const indexPath = `${this.getSortIndexBaseDirectory()}/indexes/${this.name}/${fieldName}_${direction}`;
        return await this.storage.dirExists(indexPath);
    }
        
    //
    // Find records by index using SortIndex
    //
    async findByIndex(fieldName: string, value: any): Promise<RecordT[]> {
       
        // Try to find an existing sort index for the field (check both asc and desc)
        const ascIndex = await this.loadSortIndex(fieldName, 'asc');
        if (ascIndex) {
            // Use the sort index for faster search with binary search
            return (await ascIndex.findByValue(value)).map(sortIndexEntry => ({
                _id: sortIndexEntry._id,
                ...sortIndexEntry.fields
            } as RecordT));
        }
        
        const descIndex = await this.loadSortIndex(fieldName, 'desc');
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
        const sortIndex = await this.loadSortIndex(fieldName, direction);
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
        const deleteAsc = await this.deleteSortIndex(fieldName, 'asc');
        const deleteDesc = await this.deleteSortIndex(fieldName, 'desc');
        return deleteAsc || deleteDesc;
    }
    
    //
    // Get records sorted by a specified field
    //
    async getSorted(fieldName: string, direction: SortDirection, pageId?: string): Promise<ISortResult<RecordT>> {
        const sortIndex = await this.loadSortIndex(fieldName, direction);
        if (!sortIndex) {
            throw new Error(`Sort index for field "${fieldName}" in direction "${direction}" does not exist.`);
        }
        
        const sortedRecords = await sortIndex.getPage(pageId);
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
    async ensureSortIndex(fieldName: string, direction: SortDirection, type: SortDataType, progressCallback?: (message: string) => void): Promise<void> {
        const sortIndex = await this.createSortIndex(fieldName, direction, type, this.defaultPageSize);
        if (!await sortIndex.load()) {
            await sortIndex.build(this, progressCallback);
        }
    }

    //
    // Loads the sort index.
    //
    private async loadSortIndexInternal(fieldName: string, direction: SortDirection, type: SortDataType): Promise<void> {
        const sortIndex = await this.createSortIndex(fieldName, direction, type, this.defaultPageSize);
        if (!await sortIndex.load()) {
            console.error(`Sort index for field "${fieldName}" in direction "${direction}" does not exist on disk.`);
        }
    }

    //
    // Load a sort index from storage.
    //
    async loadSortIndexFromStorage(fieldName: string, direction: SortDirection, type: SortDataType): Promise<void> {
        await this.loadSortIndexInternal(fieldName, direction, type);
    }

    //
    // List all sort indexes for this collection
    //
    async listSortIndexes(): Promise<Array<{ fieldName: string; direction: SortDirection; }>> {              
        const collectionIndexPath = `${this.getSortIndexBaseDirectory()}/indexes/${this.name}`;

        if (!await this.storage.dirExists(collectionIndexPath)) {
            return [];
        }

        const result = await this.storage.listDirs(collectionIndexPath, 1000);
        const directories = result.names || [];
        
        const sortIndexes: Array<{fieldName: string; direction: SortDirection}> = [];
        
        for (const dir of directories) {
            // Parse the directory name, which should be in format "fieldname_direction"
            const match = dir.match(/^(.+)_(asc|desc)$/);
            if (match) {
                const indexInfo = {
                    fieldName: match[1],
                    direction: match[2] as SortDirection,
                };
                sortIndexes.push(indexInfo);
            }
        }

        return sortIndexes;
    }

    //
    // Delete a sort index
    //
    async deleteSortIndex(fieldName: string, direction: SortDirection): Promise<boolean> {
        // Try to delete from disk.
        const indexPath = `${this.getSortIndexBaseDirectory()}/indexes/${this.name}/${fieldName}_${direction}`;
        if (await this.storage.dirExists(indexPath)) {
            // Create instance to call delete() which handles cleanup
            const sortIndex = this.createSortIndex(fieldName, direction);
            await sortIndex.delete();
            return true;
        }
        
        return false; // The index doesn't exist
    }

    //
    // Drops the whole collection.
    //
    async drop(): Promise<void> {       
        // Delete sort indexes if any (v6: indexes/<collectionName>)
        const collectionIndexPath = `${this.getSortIndexBaseDirectory()}/indexes/${this.name}`;
        if (await this.storage.dirExists(collectionIndexPath)) {
            await this.storage.deleteDir(collectionIndexPath);
        }
        
        // Delete the collection directory (which includes merkle trees)
        await this.storage.deleteDir(this.directory); 
    }
}