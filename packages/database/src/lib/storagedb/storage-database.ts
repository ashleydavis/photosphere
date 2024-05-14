import { StorageDatabaseCollection } from "./storage-database-collection";
import { IStorage } from "../storage/storage";
import { IDatabase } from "../database";
import { IDatabaseCollection } from "../database-collection";
import { StorageDirectory } from "../storage/storage-directory";

//
// Implements a database on file storage.
//
export class StorageDatabase implements IDatabase {

    private storage: IStorage;

    constructor(storage: IStorage, path?: string) {
        if (path) {
            this.storage = new StorageDirectory(storage, path);
        }
        else {
            this.storage = storage;
        }
    }

    //
    // Gets a database collection by name.
    //
    collection<RecordT>(collectionName: string): IDatabaseCollection<RecordT> {
        return new StorageDatabaseCollection<RecordT>(this.storage, collectionName);
    }
}