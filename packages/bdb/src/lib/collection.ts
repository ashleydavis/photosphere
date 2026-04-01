//
// A collection in a database that stores BSON records in a sharded format.
//

import { pathJoin, type IStorage } from 'storage';
import type { IUuidGenerator, ITimestampProvider } from 'utils';
import { SortIndex, type ISortIndex, type SortDirection } from './sort-index';
import { updateMetadata } from './update-metadata';
import { updateFields } from './update-fields';
import {
    saveCollectionMerkleTree,
    loadCollectionMerkleTree,
    deleteCollectionMerkleTree,
} from './merkle-tree';
import { createTree } from 'merkle-tree';
import { IMerkleRef, MerkleRef } from './merkle-tree-ref';
import * as crypto from 'crypto';
import { BsonShard, type IInternalRecord, type IShard } from './shard';

//
// Options needed to construct a sort index (caller adds fieldName and direction).
//
export interface ISortIndexCreationOptions {
    //
    // Storage backend for sort index files.
    //
    storage: IStorage;

    //
    // BSON database root directory (indexes live under this tree).
    //
    baseDirectory: string;

    //
    // Collection name segment in index paths.
    //
    collectionName: string;

    //
    // UUID generator for new sort index node IDs.
    //
    uuidGenerator: IUuidGenerator;
}

//
// Public document shape: required id plus arbitrary application fields.
//
export interface IRecord {
    //
    // Document id (UUID string).
    //
    _id: string;

    //
    // Application-defined fields (everything except _id).
    //
    [key: string]: any;
}

//
// Per-field version metadata: root timestamp plus optional nested field metadata (recursive).
//
export interface Metadata {
    //
    // Last modification time for this value or subtree (Unix ms or logical clock).
    //
    timestamp?: number;

    //
    // Nested field metadata keyed by field name (same structure as values).
    //
    fields?: {
        [key: string]: Metadata;
    };
};

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
// One page of records from getAll plus an optional continuation token for the next shard slice.
//
export interface IGetAllResult<RecordT extends IRecord> {
    //
    // Records returned for this request.
    //
    records: RecordT[];

    //
    // Opaque token to pass to getAll() to fetch the next page, if any.
    //
    next?: string;
}

//
// Number of shard buckets for record distribution (record id hash mod NUM_SHARDS).
//
const NUM_SHARDS = 100;

//
// BSON collection API: CRUD, sort indexes, sharding, and deferred commit/flush.
//
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
    // List all sort indexes for this collection
    //
    sortIndexes(): Promise<Array<{
        fieldName: string;
        direction: SortDirection;
    }>>;

    //
    // Returns the sort index for the given field and direction (lazily loaded on first use).
    //
    sortIndex(fieldName: string, direction: SortDirection): ISortIndex<RecordT>;

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
    deleteOne(recordId: string): Promise<boolean>;

    //
    // Drops the whole collection.
    //
    drop(): Promise<void>;

    //
    // Returns the shard bucket for shardId (cached; call load() or merkle to read BSON from disk).
    //
    shard(shardId: string): IShard;

    //
    // Returns the shard id for a record (for replication batching).
    //
    getShardId(recordId: string): string;

    //
    // Collection merkle ref (lazily loads from disk or builds on first use).
    //
    merkleTree(): IMerkleRef;

    //
    // True if this collection has uncommitted changes since the last commit.
    //
    dirty(): boolean;

    //
    // Flushes all pending writes to disk: dirty shards, merkle trees, and sort index pages.
    // Dirty flags are cleared; the in-memory cache remains populated for fast subsequent reads.
    // Returns the current collection merkle tree for the database to incorporate.
    //
    commit(): Promise<void>;

    //
    // Flushes the cache.
    //
    flush(): void;
}

//
// Sharded BSON document store: records partitioned into shard files, sort indexes, and merkle trees.
// Writes are buffered until commit(); flush() drops caches after a successful commit.
//
export class BsonCollection<RecordT extends IRecord> implements IBsonCollection<RecordT> {
    //
    // Backing storage for shard files, merkle files, and sort indexes.
    //
    private storage: IStorage;

    //
    // Root passed to sort indexes (indexes/...); usually the same path as bsonDbPath.
    //
    private readonly baseDirectory: string;

    //
    // UUID generator for creating unique identifiers.
    //
    private readonly uuidGenerator: IUuidGenerator;

    //
    // Timestamp provider for generating timestamps.
    //
    private readonly timestampProvider: ITimestampProvider;

    //
    // Cache of sort indexes, keyed by "fieldName_direction".
    // Each sort index lazily loads from disk on first use.
    //
    private readonly sortIndexCache = new Map<string, SortIndex>();

    // Shard cache; each shard carries a dirty flag until commit (BSON + merkle).
    private readonly shardCache = new Map<string, BsonShard>();

    // Lazily-created ref for this collection's merkle tree.
    private _merkleRef: MerkleRef | undefined = undefined;

    // Aggregate dirty flag — true if any child is dirty since last commit
    private _dirty = false;

    // Callback to notify the database when this collection first becomes dirty; receives the collection name.
    private readonly onDirtyCallback: () => void;

    //
    // name — collection id; bsonDbPath — database root in storage (shard/merkle paths use bsonDbPath/collections/name/...).
    // baseDirectory — BSON root passed to sort indexes (usually same as bsonDbPath).
    // onDirty — invoked on first transition to dirty each commit cycle.
    //
    constructor(
        private readonly name: string,
        private readonly bsonDbPath: string,
        storage: IStorage,
        baseDirectory: string,
        uuidGenerator: IUuidGenerator,
        timestampProvider: ITimestampProvider,
        onDirty: () => void,
    ) {
        this.storage = storage;
        this.baseDirectory = baseDirectory;
        this.uuidGenerator = uuidGenerator;
        this.timestampProvider = timestampProvider;
        this.onDirtyCallback = onDirty;
    }

    //
    // True if this collection has uncommitted changes since the last commit.
    //
    dirty(): boolean {
        return this._dirty;
    }

    //
    // Sets the dirty flag and fires the onDirty callback on first transition per commit cycle.
    //
    private markDirty(): void {
        if (!this._dirty) {
            this._dirty = true;
            this.onDirtyCallback();
        }
    }

    //
    // Clears the dirty flag after a successful commit or drop.
    //
    private clearDirty(): void {
        this._dirty = false;
    }

    //
    // Returns the sort index for the given field and direction (lazily loaded on first use).
    // The sort index is created and cached synchronously; disk access is deferred until first operation.
    //
    sortIndex(fieldName: string, direction: SortDirection): ISortIndex<RecordT> {
        const cacheKey = `${fieldName}_${direction}`;
        const cached = this.sortIndexCache.get(cacheKey);
        if (cached) {
            return cached as unknown as ISortIndex<RecordT>;
        }
        const sortIndex = new SortIndex(
            this.storage,
            this.baseDirectory,
            this.name,
            fieldName,
            direction,
            this.uuidGenerator,
            undefined, //todo: Might be good if the data type was passed into sortIndex as well!
            () => this.markDirty(),
            () => this.sortIndexCache.delete(cacheKey),
        );

        this.sortIndexCache.set(cacheKey, sortIndex);
        return sortIndex as unknown as ISortIndex<RecordT>;
    }

    //
    // Adds a record to all sort indexes for this collection.
    //
    private async addRecordToSortIndexes(record: IInternalRecord): Promise<void> {
        const indexes = await this.sortIndexes();
        for (const indexInfo of indexes) {
            await this.sortIndex(indexInfo.fieldName, indexInfo.direction).addRecord(record);
        }
    }

    //
    // Updates a record in all sort indexes.
    //
    private async updateRecordInSortIndexes(updatedRecord: IInternalRecord, oldRecord: IInternalRecord | undefined): Promise<void> {
        const indexes = await this.sortIndexes();
        for (const indexInfo of indexes) {
            await this.sortIndex(indexInfo.fieldName, indexInfo.direction).updateRecord(updatedRecord, oldRecord);
        }
    }

    //
    // Deletes a record from all existing sort indexes.
    //
    private async deleteRecordFromSortIndexes(recordId: string, record: IInternalRecord): Promise<void> {
        const indexes = await this.sortIndexes();
        for (const indexInfo of indexes) {
            await this.sortIndex(indexInfo.fieldName, indexInfo.direction).deleteRecord(recordId, record);
        }
    }

    //
    // Returns the collection merkle ref (lazily loads from disk or builds on first use).
    //
    merkleTree(): IMerkleRef {
        if (!this._merkleRef) {
            this._merkleRef = new MerkleRef(
                async () => loadCollectionMerkleTree(this.storage, this.bsonDbPath, this.name),
                async (tree) => saveCollectionMerkleTree(this.storage, this.bsonDbPath, this.name, tree),
                async () => deleteCollectionMerkleTree(this.storage, this.bsonDbPath, this.name),
                async () => createTree<undefined>(this.uuidGenerator.generate()),
            );
        }
        return this._merkleRef;
    }


    //
    // Returns the shard bucket for shardId (creates and caches a BsonShard; BSON reads are lazy).
    //
    shard(shardId: string): IShard {
        const cached = this.shardCache.get(shardId);
        if (cached) {
            return cached;
        }
        const bsonShard = new BsonShard(shardId, this.storage, this.bsonDbPath, this.name, this.uuidGenerator);
        this.shardCache.set(shardId, bsonShard);
        return bsonShard;
    }

    //
    // Returns the shard id for a record (hash of id mod numShards).
    //
    getShardId(recordId: string): string {
        const recordIdBuffer = Buffer.from(recordId.replace(/-/g, ''), 'hex');
        if (recordIdBuffer.length !== 16) {
            throw new Error(`Invalid record ID ${recordId} with length ${recordIdBuffer.length}`);
        }

        const hash = crypto.createHash('md5').update(recordIdBuffer).digest('hex');
        const decimal = parseInt(hash.substring(0, 8), 16);
        return (decimal % NUM_SHARDS).toString();
    }

    //
    // Insert a new record into the collection.
    // Throws an error if a document with the same ID already exists.
    //
    async insertOne(record: RecordT, options?: { timestamp?: number }): Promise<void> {
        if (!record._id) {
            record._id = this.uuidGenerator.generate();
        }

        const shardId = this.getShardId(record._id);
        const shard = this.shard(shardId);
        if (await shard.record(record._id)) {
            throw new Error(`Document with ID ${record._id} already exists in shard ${shardId}`);
        }

        const versionTimestamp = options?.timestamp ?? this.timestampProvider.now();
        const internalRecord = toInternal<RecordT>(record, versionTimestamp);
        await shard.setRecord(record._id, internalRecord);
        await this.addRecordToSortIndexes(internalRecord);

        this.markDirty();
    }

    //
    // Gets one record by ID.
    //
    async getOne(id: string): Promise<RecordT | undefined> {
        const shardId = this.getShardId(id);
        const shard = this.shard(shardId);

        const record = await shard.record(id);
        if (!record) {
            return undefined; // Record not found
        }

        return toExternal<RecordT>(record);
    }

    //
    // Iterate all records in the collection without loading all into memory.
    //
    async *iterateRecords(): AsyncGenerator<IInternalRecord, void, unknown> {
        for (let shardId = 0; shardId < NUM_SHARDS; shardId++) {
            const shard = this.shard(shardId.toString());
            const records = await shard.records();
            for (const record of records.values()) {
                yield record;
            }
        }
    }

    //
    // Iterate each shard in the collection without loading all into memory.
    // Yields only shards that have records.
    //
    async *iterateShards(): AsyncGenerator<Iterable<IInternalRecord>, void, unknown> {
        for (let shardId = 0; shardId < NUM_SHARDS; shardId++) {
            const shard = this.shard(shardId.toString());
            const records = await shard.records();
            if (records.size > 0) {
                yield records.values();
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
        while (shardId < NUM_SHARDS) {
            const shard = this.shard(shardId.toString());
            const records = await shard.records();
            if (records.size > 0) {
                return { 
                    records: Array.from(records.values()).map(internal => toExternal<RecordT>(internal)),
                    next: `${shardId + 1}` 
                };
            }

            shardId += 1;
        }

        return { records: [], next: undefined }; // No more records
    }

    //
    // Updates a record.
    //
    async updateOne(id: string, updates: Partial<Omit<RecordT, '_id'>>, options?: { upsert?: boolean; timestamp?: number }): Promise<boolean> {
        const shardId = this.getShardId(id);
        const shard = this.shard(shardId);

        let existingRecord = await shard.record(id);

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

        await shard.setRecord(id, updatedRecord);
        await this.updateRecordInSortIndexes(updatedRecord, existingRecord);

        this.markDirty();

        return true;
    }

    //
    // Replaces a record with completely new data.
    //
    async replaceOne(id: string, record: RecordT, options?: { upsert?: boolean; timestamp?: number }): Promise<boolean> {
        const shardId = this.getShardId(id);
        const shard = this.shard(shardId);

        const existingRecord = await shard.record(id);

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
        await shard.setRecord(id, internalRecord);
        await this.updateRecordInSortIndexes(internalRecord, existingRecord);

        this.markDirty();

        return true;
    }

    //
    // Sets an internal record directly, preserving all timestamps and metadata.
    // This is useful for sync operations where timestamps must be preserved exactly.
    // Always upserts (creates if doesn't exist, updates if it does).
    //
    async setInternalRecord(record: IInternalRecord): Promise<void> {
        const shardId = this.getShardId(record._id);
        const shard = this.shard(shardId);

        const existingRecord = await shard.record(record._id);

        // Set the record directly with all its metadata preserved
        await shard.setRecord(record._id, record);
        await this.updateRecordInSortIndexes(record, existingRecord);

        this.markDirty();
    }

    //
    // Deletes a record.
    //
    async deleteOne(recordId: string): Promise<boolean> {
        const shardId = this.getShardId(recordId);
        const shard = this.shard(shardId);

        //
        // Find the record to delete.
        //
        const existingRecord = await shard.record(recordId);
        if (!existingRecord) {
            return false; // Record not found
        }

        //
        // Delete the record.
        //
        await shard.deleteRecord(recordId);
        await this.deleteRecordFromSortIndexes(recordId, existingRecord);
        this.markDirty(); 

        return true;
    }   

    //
    // List all sort indexes for this collection
    //
    async sortIndexes(): Promise<Array<{ fieldName: string; direction: SortDirection; }>> {              
        const collectionIndexPath = `${this.baseDirectory}/indexes/${this.name}`;

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
    // Drops the whole collection.
    //
    async drop(): Promise<void> {       
        // Delete sort indexes if any (v6: indexes/<collectionName>)
        const collectionIndexPath = `${this.baseDirectory}/indexes/${this.name}`;
        if (await this.storage.dirExists(collectionIndexPath)) {
            await this.storage.deleteDir(collectionIndexPath);
        }
        this.sortIndexCache.clear();

        // Delete the collection directory (which includes merkle trees)
        await this.storage.deleteDir(pathJoin(this.bsonDbPath, "collections", this.name));

        // Clear all caches and dirty state
        this.shardCache.clear();
        this._merkleRef = undefined;
        this.clearDirty();
    }

    //
    // Flushes all pending writes to disk: dirty shards, merkle trees, and sort index pages.
    // Dirty flags are cleared; the in-memory cache remains populated for fast subsequent reads.
    // Returns the current collection merkle tree for the database to incorporate.
    //
    async commit(): Promise<void> {

        for (const [shardId, shard] of this.shardCache.entries()) {
            if (!shard.dirty()) {
                continue;
            }

            await shard.commit();

            const shardTree = await shard.merkleTree().get();
            if (shardTree && shardTree.merkle) {
                await this.merkleTree().upsert({
                    name: shardId,
                    hash: shardTree.merkle.hash,
                    length: shardTree.merkle.nodeCount,
                    lastModified: new Date(),
                });
            }
            else {
                await this.merkleTree().remove(shardId);
            }
        }

        for (const sortIndex of this.sortIndexCache.values()) {
            await sortIndex.commit();
        }

        await this.merkleTree().commit();

        this.clearDirty();
    }

    //
    // Flushes the cache.
    //
    flush(): void {
        if (this._dirty) {
            throw new Error(`Collection ${this.name} is dirty, can't flush the cache.`);
        }

        for (const shard of this.shardCache.values()) {
            shard.flush();
        }

        for (const sortIndex of this.sortIndexCache.values()) {
            sortIndex.flush();
        }

        this.sortIndexCache.clear();
        this.shardCache.clear();
        this._merkleRef?.flush();
        this._merkleRef = undefined;
    }
}
