//
// Implements a BSON-based database that can store multiple collections of documents.
//

import type { IStorage } from "storage";
import { BsonCollection } from "./collection";
import type { IRecord, IBsonCollection } from "./collection";
import type { IUuidGenerator, ITimestampProvider } from "utils";
import { IMerkleTree } from "merkle-tree";

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

    //
    // Timestamp provider for generating timestamps.
    //
    timestampProvider: ITimestampProvider;
}

export class BsonDatabase implements IBsonDatabase {

    //
    // Caches created collections.
    //
    private _collections = new Map<string, IBsonCollection<IRecord>>();

    constructor(private options: IBsonDatabaseOptions) {        
    }

    //
    // Gets the names of all collections in the database (v6 layout: list collections/ subdir).
    //
    async collections(): Promise<string[]> {

        const uniqueSet = new Set<string>();

        if (await this.options.storage.dirExists("collections")) {
            let next: string | undefined = undefined;
            do {
                const storageResult = await this.options.storage.listDirs("collections", 1000, next);
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
            coll = new BsonCollection<IRecord>(name, {
                storage: this.options.storage,
                directory: `collections/${name}`,
                baseDirectory: "",
                uuidGenerator: this.options.uuidGenerator,
                timestampProvider: this.options.timestampProvider
            });
            this._collections.set(name, coll);
        }
        return coll as IBsonCollection<RecordT>;
    }
}