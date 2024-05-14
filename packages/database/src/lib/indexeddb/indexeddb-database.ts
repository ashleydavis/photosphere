import { IDatabase } from "../database";
import { IDatabaseCollection } from "../database-collection";
import { IIndexeddbDatabaseCollection } from "./indexeddb-database-collection";

//
// Implements a database.
//
export class IIndexeddbDatabase implements IDatabase {
    constructor(private indexedDB: IDBDatabase) {
    }

    //
    // Gets a database collection by name.
    //
    collection<RecordT>(collectionName: string): IDatabaseCollection<RecordT> {
        return new IIndexeddbDatabaseCollection<RecordT>(this.indexedDB, collectionName);
    }
}
