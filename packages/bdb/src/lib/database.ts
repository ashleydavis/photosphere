//
// Implements a BSON-based database that can store multiple collections of documents.
//

import { pathJoin, type IStorage } from "storage";
import { BsonCollection } from "./collection";
import type { IRecord, IBsonCollection } from "./collection";
import type { IUuidGenerator, ITimestampProvider } from "utils";
import { MerkleNode, buildMerkleTree, createTree } from "merkle-tree";
import { IMerkleRef, MerkleRef } from "./merkle-tree-ref";
import {
    loadDatabaseMerkleTree,
    saveDatabaseMerkleTree,
    deleteDatabaseMerkleTree,
} from "./merkle-tree";

export interface IBsonDatabase {

    //
    // Gets the names of all collections in the database.
    //
    collections(): Promise<string[]>;

    //
    // Gets a named collection.
    //
    collection<RecordT extends IRecord>(name: string): IBsonCollection<RecordT>;

    //
    // Flushes all pending writes to disk across all collections and updates the database merkle tree.
    // Dirty flags are cleared; the in-memory cache remains populated for fast subsequent reads.
    //
    commit(): Promise<void>;

    //
    // Flushes the cache.
    //
    flush(): void;

    //
    // Gets the database merkle tree.
    //
    merkleTree(): IMerkleRef;
}

export class BsonDatabase implements IBsonDatabase {

    //
    // Caches created collections.
    //
    private _collections = new Map<string, IBsonCollection<IRecord>>();

    //
    // Lazily-created ref for the database-level merkle tree.
    //
    private _merkleRef: MerkleRef | undefined = undefined;

    //
    // Aggregate dirty flag — true if any collection is dirty since last commit.
    //
    private dirty = false;

    constructor(
        private readonly storage: IStorage,
        private readonly bsonDbPath: string,
        private readonly uuidGenerator: IUuidGenerator,
        private readonly timestampProvider: ITimestampProvider,
    ) {
    }

    //
    // Marks the database as having uncommitted changes.
    //
    private markDirty(): void {
        this.dirty = true;
    }

    //
    // Clears the dirty flag after a successful commit.
    //
    private clearDirty(): void {
        this.dirty = false;
    }

    //
    // Gets the names of all collections in the database.
    //
    async collections(): Promise<string[]> {

        const uniqueSet = new Set<string>();

        const collectionsPath = pathJoin(this.bsonDbPath, "collections");
        if (await this.storage.dirExists(collectionsPath)) {
            let next: string | undefined = undefined;
            do {
                const storageResult = await this.storage.listDirs(collectionsPath, 1000, next);
                for (const name of storageResult.names) {
                    uniqueSet.add(name);
                }
                next = storageResult.next;
            } while (next);
        }

        for (const name of this._collections.keys()) {
            uniqueSet.add(name);
        }

        return Array.from(uniqueSet);
    }

    //
    // Gets a named collection (v6 layout: directory = collections/<name>).
    //
    collection<RecordT extends IRecord>(name: string): IBsonCollection<RecordT> {
        let coll = this._collections.get(name);
        if (!coll) {
            coll = new BsonCollection<IRecord>(
                name,
                this.bsonDbPath,
                this.storage,
                this.bsonDbPath,
                this.uuidGenerator,
                this.timestampProvider,
                () => this.markDirty(),
            );
            this._collections.set(name, coll);
        }
        return coll as IBsonCollection<RecordT>;
    }

    //
    // Flushes all pending writes to disk across all collections and updates the database merkle tree.
    // Dirty flags are cleared; the in-memory cache remains populated for fast subsequent reads.
    //
    async commit(): Promise<void> {
        if (!this.dirty) {
            return;
        }

        for (const [collName, coll] of this._collections.entries()) {
            if (!coll.dirty()) {
                continue;
            }

            await coll.commit();

            const collMerkle = await coll.merkleTree().get();
            if (collMerkle && collMerkle.merkle) {
                await this.merkleTree().upsert({
                    name: collName,
                    hash: collMerkle.merkle.hash,
                    length: collMerkle.merkle.nodeCount,
                    lastModified: new Date(),
                });
            }
            else {
                await this.merkleTree().remove(collName);
            }
        }

        await this.merkleTree().commit();
        this.clearDirty();
    }

    //
    // Ejects all cached data from memory across all collections.
    // Throws if there are uncommitted changes — call commit() first.
    //
    flush(): void {
        if (this.dirty) {
            throw new Error('Cannot flush: database has uncommitted changes. Call commit() first.');
        }

        for (const coll of this._collections.values()) {
            coll.flush();
        }

        this._merkleRef?.flush();
        this._merkleRef = undefined;
    }

    //
    // Returns the database-level merkle ref, creating it on first use.
    //
    merkleTree(): IMerkleRef {
        if (!this._merkleRef) {
            this._merkleRef = new MerkleRef(
                async () => loadDatabaseMerkleTree(this.storage, this.bsonDbPath),
                async (tree) => saveDatabaseMerkleTree(this.storage, this.bsonDbPath, tree),
                async () => deleteDatabaseMerkleTree(this.storage, this.bsonDbPath),
                async () => createTree<undefined>(this.uuidGenerator.generate()),
            );
        }
        return this._merkleRef;
    }
}
