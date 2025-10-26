//
// Implements a BSON-based database that can store multiple collections of documents.
//

import type { IStorage } from "storage";
import { BsonCollection } from "./collection";
import type { IRecord, IBsonCollection } from "./collection";
import type { IUuidGenerator } from "utils";

export interface IBsonDatabase {

    //
    // Gets the names of all collections in the database.
    //
    collections(): Promise<string[]>;

    //
    // Gets a named collection.
    //
    collection<RecordT extends IRecord>(name: string): IBsonCollection<RecordT>;
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
                // Filter out system directories
                if (name !== 'sort_indexes') {
                    uniqueSet.add(name);
                }
            }
            next = storageResult.next;
        } while (next);

        for (const name of this._collections.keys()) {
            // Also filter out system directories from cached collections
            if (name !== 'sort_indexes') {
                uniqueSet.add(name);
            }
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
                uuidGenerator: this.options.uuidGenerator
            });
            this._collections.set(name, collection);
        }        
        return collection as IBsonCollection<RecordT>;
    }
}