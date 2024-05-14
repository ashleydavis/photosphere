import { IDatabase } from "../database";
import { IDatabases } from "../databases";
import { IStorage } from "../storage/storage";
import { StorageDatabase } from "./storage-database";


export class StorageDatabases implements IDatabases {

    constructor(private storage: IStorage) {
    }

    //
    // Gets a database by name.
    //   
    async database(databaseName: string): Promise<IDatabase> {
        return new StorageDatabase(this.storage, databaseName);
    }
}
