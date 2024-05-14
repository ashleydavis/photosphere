import { IDatabase } from "../database";
import { IDatabaseCollection } from "../database-collection";
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
    collection<RecordT>(collectionName: string): IDatabaseCollection<RecordT> {
        return new IndexeddbDatabaseCollection<RecordT>(collectionName, this.openDb);
    }
}
