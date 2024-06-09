import { IDatabase } from "../database";
import { IRecord } from "../database-collection";
import { IIndexeddbDatabaseCollection, IndexeddbDatabaseCollection } from "./indexeddb-database-collection";

export interface IIndexeddbDatabase extends IDatabase {
    //
    // Unwraps the indexeddb database.
    //
    getIndexedDb(): Promise<IDBDatabase>;
}

//
// Implements a database.
//
export class IndexeddbDatabase implements IIndexeddbDatabase {
    constructor(private openDb: () => Promise<IDBDatabase>) {
    }

    //
    // Gets a database collection by name.
    //
    collection<RecordT extends IRecord>(collectionName: string): IIndexeddbDatabaseCollection<RecordT> {
        return new IndexeddbDatabaseCollection<RecordT>(collectionName, this.openDb);
    }

    //
    // Unwraps the indexeddb database.
    //
    async getIndexedDb(): Promise<IDBDatabase> {
        return this.openDb();
    }
}
