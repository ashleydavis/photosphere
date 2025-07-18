//
// Implements a BSON-based database that can store multiple collections of documents.
//

import { IStorage } from "../storage";
import { BsonCollection, IRecord, type IBsonCollection } from "./collection";
import { IUuidGenerator } from "utils";

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
    // Writes all pending changes to the database and shuts down the database.
    //
    close(): Promise<void>;
}

//
// Options when creating a BSON database.
//
export interface IBsonDatabaseOptions {
    //
    // Interface to the file storage system.
    //
    storage: IStorage;

    //
    // UUID generator for creating unique identifiers.
    //
    uuidGenerator: IUuidGenerator;

    //
    // The maximum number of shards to keep in memory.
    //
    maxCachedShards?: number;
}

export class BsonDatabase implements IBsonDatabase { //todo: move to bdb package.

    //
    // Caches created collections.
    //
    private _collections = new Map<string, IBsonCollection<IRecord>>();

    constructor(private options: IBsonDatabaseOptions) {        
    }

    //
    // Gets the names of all collections in the database.
    //
    async collections(): Promise<string[]> {

        const uniqueSet = new Set<string>();

        let next: string | undefined = undefined;
        do {
            const storageResult = await this.options.storage.listDirs("", 1000, next);
            for (const name of storageResult.names) { 
                uniqueSet.add(name);
            }
            next = storageResult.next;
        } while (next);

        for (const name of this._collections.keys()) {
            uniqueSet.add(name);
        }

        return Array.from(uniqueSet);
    }

    //
    // Gets a named collection.
    //
    collection<RecordT extends IRecord>(name: string): IBsonCollection<RecordT> {
        let collection = this._collections.get(name);
        if (!collection) {
            collection = new BsonCollection<IRecord>(name, {
                storage: this.options.storage,
                directory: name,
                uuidGenerator: this.options.uuidGenerator,
                maxCachedShards: this.options.maxCachedShards,
            });
            this._collections.set(name, collection);
        }        
        return collection as IBsonCollection<RecordT>;
    }

    //
    // Writes all pending changes to the database and shuts down the database.
    //
    async close(): Promise<void> {
        for (let collection of this._collections.values()) {
            await collection.shutdown();
        }

        this._collections.clear();
    }
}