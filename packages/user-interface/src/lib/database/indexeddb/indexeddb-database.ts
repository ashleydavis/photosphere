import { IDatabase } from "../database";
import { IDatabaseCollection, IRecord } from "../database-collection";
import { IndexeddbDatabaseCollection } from "./indexeddb-database-collection";

//
// Implements a database.
//
export class IndexeddbDatabase implements IDatabase {
    constructor(private openDb: () => Promise<IDBDatabase>) {
    }

    //
    // Gets a database collection by name.
    //
    collection<RecordT extends IRecord>(collectionName: string): IDatabaseCollection<RecordT> {
        return new IndexeddbDatabaseCollection<RecordT>(collectionName, this.openDb);
    }
}
