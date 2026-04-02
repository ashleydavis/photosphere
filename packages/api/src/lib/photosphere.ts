import { IBsonDatabase, IBsonCollection, MerkleRef, IMerkleRef } from "bdb";
import { IStorage } from "storage";
import { IUuidGenerator, ITimestampProvider } from "utils";
import { IAsset } from "defs";
import { createTree } from "merkle-tree";
import {
    createMediaFileDatabase,
    getDatabaseSummary,
    streamAsset,
    writeAsset,
    writeAssetStream,
    removeAsset,
    IDatabaseSummary,
    IDatabaseMetadata,
} from "./media-file-database";
import { loadMerkleTree, saveMerkleTree } from "./tree";
import {
    acquireWriteLock as acquireWriteLockPrimitive,
    refreshWriteLock as refreshWriteLockPrimitive,
    releaseWriteLock as releaseWriteLockPrimitive,
} from "./write-lock";

//
// Unified interface for all database operations.
// Provides access to the BSON database, files tree, and metadata collection,
// plus high-level convenience methods for common asset operations.
//
export interface IPsi {
    //
    // Returns the underlying BSON database.
    //
    database(): IBsonDatabase;

    //
    // Returns the lazily-loaded merkle ref for the files tree.
    //
    files(): IMerkleRef<IDatabaseMetadata>;

    //
    // Returns the metadata collection for asset records.
    //
    metadata(): IBsonCollection<IAsset>;

    //
    // Acquires the write lock for the database. Throws if lock cannot be acquired.
    //
    acquireWriteLock(): Promise<void>;

    //
    // Refreshes the write lock to prevent timeout.
    //
    refreshWriteLock(): Promise<void>;

    //
    // Releases the write lock for the database.
    //
    releaseWriteLock(): Promise<void>;

    //
    // Commits all pending writes to disk.
    //
    commit(): Promise<void>;

    //
    // Flushes the in-memory cache.
    //
    flush(): void;

    //
    // Returns a summary of the database.
    //
    summary(): Promise<IDatabaseSummary>;

    //
    // Streams an asset from the database.
    //
    stream(assetId: string, assetType: string): Promise<NodeJS.ReadableStream>;

    //
    // Writes an asset from a buffer.
    //
    write(assetId: string, assetType: string, contentType: string | undefined, buffer: Buffer): Promise<void>;

    //
    // Writes an asset from a readable stream.
    //
    writeStream(assetId: string, assetType: string, contentType: string | undefined, inputStream: NodeJS.ReadableStream, contentLength: number | undefined): Promise<void>;

    //
    // Removes an asset from the database by ID.
    //
    remove(assetId: string, recordDeleted: boolean): Promise<void>;
}

//
// Concrete implementation of IPsi.
//
export class Psi implements IPsi {
    //
    // The BSON database instance.
    //
    private readonly _bsonDatabase: IBsonDatabase;

    //
    // The metadata collection for asset records.
    //
    private readonly _metadataCollection: IBsonCollection<IAsset>;

    //
    // Lazily-created merkle ref for the files tree.
    //
    private _filesRef: MerkleRef<IDatabaseMetadata> | undefined = undefined;

    constructor(
        //
        // Asset storage (may be encrypted).
        //
        private readonly _assetStorage: IStorage,

        //
        // Raw (unencrypted) storage used for write lock operations.
        //
        private readonly _rawStorage: IStorage,

        //
        // Session identifier for write lock tracking.
        //
        private readonly _sessionId: string,

        //
        // UUID generator used for creating new tree identifiers.
        //
        private readonly _uuidGenerator: IUuidGenerator,

        //
        // Timestamp provider passed through to the BSON database.
        //
        timestampProvider: ITimestampProvider,
    ) {
        const db = createMediaFileDatabase(_assetStorage, _uuidGenerator, timestampProvider);
        this._bsonDatabase = db.bsonDatabase;
        this._metadataCollection = db.metadataCollection;
    }

    //
    // Returns the underlying BSON database.
    //
    database(): IBsonDatabase {
        return this._bsonDatabase;
    }

    //
    // Returns the lazily-loaded merkle ref for the files tree, creating it on first use.
    //
    files(): IMerkleRef<IDatabaseMetadata> {
        if (!this._filesRef) {
            this._filesRef = new MerkleRef<IDatabaseMetadata>(
                async () => loadMerkleTree(this._assetStorage),
                async (tree) => saveMerkleTree(tree, this._assetStorage),
                async () => this._assetStorage.deleteFile(".db/files.dat"),
                async () => createTree<IDatabaseMetadata>(this._uuidGenerator.generate()),
            );
        }
        return this._filesRef;
    }

    //
    // Returns the metadata collection for asset records.
    //
    metadata(): IBsonCollection<IAsset> {
        return this._metadataCollection;
    }

    //
    // Acquires the write lock. Throws if the lock cannot be acquired.
    //
    async acquireWriteLock(): Promise<void> {
        if (!await acquireWriteLockPrimitive(this._rawStorage, this._sessionId)) {
            throw new Error(`Failed to acquire write lock.`);
        }
    }

    //
    // Refreshes the write lock to prevent timeout.
    //
    async refreshWriteLock(): Promise<void> {
        await refreshWriteLockPrimitive(this._rawStorage, this._sessionId);
    }

    //
    // Releases the write lock.
    //
    async releaseWriteLock(): Promise<void> {
        await releaseWriteLockPrimitive(this._rawStorage);
    }

    //
    // Commits all pending writes to disk.
    //
    async commit(): Promise<void> {
        await this._bsonDatabase.commit();
    }

    //
    // Flushes the in-memory cache.
    //
    flush(): void {
        this._bsonDatabase.flush();
    }

    //
    // Returns a summary of the database.
    //
    async summary(): Promise<IDatabaseSummary> {
        return getDatabaseSummary(this._assetStorage);
    }

    //
    // Streams an asset from the database.
    //
    async stream(assetId: string, assetType: string): Promise<NodeJS.ReadableStream> {
        return streamAsset(this._assetStorage, assetId, assetType);
    }

    //
    // Writes an asset from a buffer.
    //
    async write(assetId: string, assetType: string, contentType: string | undefined, buffer: Buffer): Promise<void> {
        await writeAsset(this._assetStorage, this._rawStorage, this._sessionId, assetId, assetType, contentType, buffer);
    }

    //
    // Writes an asset from a readable stream.
    //
    async writeStream(assetId: string, assetType: string, contentType: string | undefined, inputStream: NodeJS.ReadableStream, contentLength: number | undefined): Promise<void> {
        await writeAssetStream(this._assetStorage, this._rawStorage, this._sessionId, assetId, assetType, contentType, inputStream, contentLength);
    }

    //
    // Removes an asset from the database by ID.
    //
    async remove(assetId: string, recordDeleted: boolean): Promise<void> {
        await removeAsset(this._assetStorage, this._rawStorage, this._sessionId, this._bsonDatabase, this._metadataCollection, assetId, recordDeleted);
    }
}

