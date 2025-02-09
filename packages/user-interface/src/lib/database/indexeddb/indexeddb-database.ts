import { IDatabase } from "../database";
import { IDatabaseCollection, IRecord } from "../database-collection";
import { IndexeddbDatabaseCollection } from "./indexeddb-database-collection";

//
// Implements a database.
//
export class IndexeddbDatabase implements IDatabase {
    constructor(private openDb: () => Promise<IDBDatabase>, private validCollectionNames: Set<string>) {
    }

    //
    // Gets a database collection by name.
    //
    collection<RecordT extends IRecord>(collectionName: string): IDatabaseCollection<RecordT> {
        if (!this.validCollectionNames.has(collectionName)) {
            throw new Error(`Invalid collection name: ${collectionName}`);
        }
        return new IndexeddbDatabaseCollection<RecordT>(collectionName, this.openDb);
    }
}
