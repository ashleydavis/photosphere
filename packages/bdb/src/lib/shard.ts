import { IDeserializer, load, save } from "serialization";
import type { ISerializer } from "serialization";
import type { IUuidGenerator } from "utils";
import type { Metadata } from "./collection";
import { IStorage, pathJoin } from "storage";
import {
    buildShardMerkleTree,
    deleteShardMerkleTree,
    hashRecord,
    loadShardMerkleTree,
    saveShardMerkleTree,
} from "./merkle-tree";
import { IMerkleRef, MerkleRef } from "./merkle-tree-ref";

//
// On-disk shard file format (SHAR).
//
const SHARD_FILE_VERSION = 2;

//
// Internal record structure with fields separated into a subobject.
// Used internally for storage, but converted to/from IRecord at API boundaries.
//
export interface IInternalRecord {
    //
    // The record id (UUID string).
    //
    _id: string;

    //
    // Payload fields (everything except id and metadata envelope).
    //
    fields: {
        [key: string]: any;
    };

    //
    // Field-level timestamps and tombstones for merge/sync.
    //
    metadata: Metadata;
}

//
// Normalizes a record id to the map key used within shards (32-char hex, no dashes).
//
export function getRecordKey(id: string): string {
    const idBuffer = Buffer.from(id.replace(/-/g, ''), "hex");
    if (idBuffer.length !== 16) {
        throw new Error(`Invalid record ID ${id} with length ${idBuffer.length}`);
    }
    return idBuffer.toString("hex");
}

//
// One bucket of records within a collection.
//
export interface IShard {
    //
    // Records in this shard, keyed by normalized id. Undefined until the map exists (after load() or setRecord()).
    //
    records(): Promise<Map<string, IInternalRecord>>;

    //
    // Loads records from a shard file into this shard's map (replaces prior contents).
    //
    load(): Promise<void>;

    //
    // Adds a record to this shard's in-memory map (keyed by normalized id).
    //
    setRecord(recordId: string, record: IInternalRecord): Promise<void>;

    //
    // Gets a record by logical id from this shard's map.
    //
    record(recordId: string): Promise<IInternalRecord | undefined>;

    //
    // Returns this shard's merkle ref (lazily loads from disk or builds from records on first use).
    //
    merkleTree(): IMerkleRef;

    //
    // Deletes a record by logical id from this shard's map.
    //
    deleteRecord(recordId: string): Promise<void>;

    //
    // Persists dirty shard data (BSON and merkle tree) to storage; no-op when not dirty.
    //
    commit(): Promise<void>;

    //
    // Flushes the cache.
    //
    flush(): void;
}

//
// Mutable shard instance held in the collection shard cache.
//
export class BsonShard implements IShard {

    //
    // Set to true when the shard is changed and must eventually be written to storage.
    //
    private _dirty: boolean = false;

    //
    // In-memory records; undefined until load() or the first setRecord().
    //
    private _records: Map<string, IInternalRecord> | undefined;

    //
    // Lazily-created ref for this shard's merkle tree.
    //
    private _merkleRef: MerkleRef | undefined = undefined;

    constructor(
        readonly shardId: string,
        readonly storage: IStorage,
        readonly bsonDbPath: string,
        readonly collectionName: string,
        readonly uuidGenerator: IUuidGenerator,
    ) {
    }

    dirty(): boolean {
        return this._dirty;
    }

    //
    // Marks this shard as having uncommitted BSON and/or shard merkle changes.
    //
    markDirty(): void {
        this._dirty = true;
    }

    //
    // Clears dirty after this shard's data has been written on commit.
    //
    markClean(): void {
        this._dirty = false;
    }

    //
    // Adds a record to this shard's in-memory map (keyed by normalized id).
    //
    async setRecord(recordId: string, record: IInternalRecord): Promise<void> {
        await this.load(); // Lazily load the shard.

        const key = getRecordKey(recordId);

        //
        // Add the record to the shard.
        //
        this._records!.set(key, record);

        //
        // Update the shard's merkle tree.
        //
        await this.merkleTree().upsert(hashRecord(recordId, record.fields));

        this.markDirty();
    }

    //
    // Gets a record by logical id from this shard's map.
    //
    async record(recordId: string): Promise<IInternalRecord | undefined> {
        await this.load(); // Lazily load the shard.

        if (this._records!.size === 0) {
            // No records.
            return undefined;
        }

        const key = getRecordKey(recordId);
        return this._records!.get(key);
    }

    //
    // Get the map of record it to records.
    //
    async records(): Promise<Map<string, IInternalRecord>> {
        await this.load(); // Lazily load the shard.
        return this._records!;
    }

    //
    // Deletes a record by logical id from this shard's map.
    //
    async deleteRecord(recordId: string): Promise<void> {
        await this.load(); // Lazily load the shard.
        
        if (this._records!.size === 0) {
            // No record to delete.
            return;
        }

        const key = getRecordKey(recordId);

        //
        // Remove the record from the shard.
        //
        this._records!.delete(key);

        //
        // Update the shard merkle tree.
        //
        await this.merkleTree().remove(recordId);
        this.markDirty();
    }

    //
    // Returns this shard's merkle ref (lazily loads from disk or builds from records on first use).
    //
    merkleTree(): IMerkleRef {
        if (!this._merkleRef) {
            this._merkleRef = new MerkleRef(
                async () => {
                    return await loadShardMerkleTree(this.storage, this.bsonDbPath, this.collectionName, this.shardId);
                },
                async (tree) => saveShardMerkleTree(this.storage, this.bsonDbPath, this.collectionName, this.shardId, tree),
                async () => deleteShardMerkleTree(this.storage, this.bsonDbPath, this.collectionName, this.shardId),
                async () => {
                    return await buildShardMerkleTree([], this.uuidGenerator);
                },
            );
        }
        return this._merkleRef;
    }

    //
    // Persists dirty shard data (BSON and merkle tree) to storage; no-op when not dirty.
    //
    async commit(): Promise<void> {
        if (!this._dirty) {
            return;
        }

        const shardFilePath = pathJoin(this.bsonDbPath, "collections", this.collectionName, "shards", this.shardId);
        if (this._records === undefined || this._records.size === 0) {
            if (await this.storage.fileExists(shardFilePath)) {
                await this.storage.deleteFile(shardFilePath);
            }
        }
        else {
            await this.writeBsonFile(shardFilePath);
        }

        await this.merkleTree().commit();

        this.markClean();
    }

    //
    // Flushes the cache.
    //
    flush(): void {
        if (this._dirty) {
            throw new Error(`Shard ${this.shardId} is dirty, can't flush the cache.`);
        }
        this._records = undefined;
        this._merkleRef?.flush();
    }

    //
    // Serializes a single record for shard file format v2+.
    //
    private serializeRecord(record: IInternalRecord, serializer: ISerializer): void {
        const recordIdBuffer = Buffer.from(record._id.replace(/-/g, ''), 'hex');
        if (recordIdBuffer.length !== 16) {
            throw new Error(`Invalid record ID ${record._id} with length ${recordIdBuffer.length}`);
        }
        serializer.writeBytes(recordIdBuffer);
        serializer.writeBSON(record.fields);
        serializer.writeBSON(record.metadata);
    }

    //
    // Writes all records in this shard to the serializer in a deterministic order.
    //
    private serializeShard(serializer: ISerializer): void {
        if (!this._records) {
            throw new Error('Cannot serialize shard without a records map');
        }
        serializer.writeUInt32(this._records.size);
        const sortedRecords = Array.from(this._records.values()).sort((recordA, recordB) => recordA._id.localeCompare(recordB._id));
        for (const record of sortedRecords) {
            this.serializeRecord(record, serializer);
        }
    }

    //
    // Writes the shard BSON blob to storage.
    //
    private async writeBsonFile(filePath: string): Promise<void> {
        await save(
            this.storage,
            filePath,
            this,
            SHARD_FILE_VERSION,
            'SHAR',
            (shardData, serializer) => {
                (shardData as BsonShard).serializeShard(serializer);
            }
        );
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
    // Deserializes a single record from the deserializer.
    // Delegates to version-specific deserialization functions.
    //
    //fio:
    // private deserializeRecord(deserializer: IDeserializer, fileVersion: number): IInternalRecord {
    //     if (fileVersion === 2) {
    //         return this.deserializeRecordV2(deserializer);
    //     } else if (fileVersion === 1) {
    //         return this.deserializeRecordV1(deserializer);
    //     } else {
    //         throw new Error(`Invalid file version: ${fileVersion}`);
    //     }
    // }

    //
    // Loads all records from a shard file.
    // Supports version 1 and 2.
    // Returns records in internal format.
    //
    private async loadRecords(shardFilePath: string): Promise<IInternalRecord[]> {
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
    // Loads records from a shard file into this shard's map (replaces prior contents).
    //
    async load(): Promise<void> {
        if (this._records !== undefined) {
            // Already loaded.
            return;
        }
        const shardFilePath = pathJoin(this.bsonDbPath, "collections", this.collectionName, "shards", this.shardId);
        const loaded = await this.loadRecords(shardFilePath);
        this._records = new Map();
        for (const record of loaded) {
            const key = getRecordKey(record._id);
            this._records.set(key, record);
        }
        this._merkleRef = undefined;
    }
    
}
