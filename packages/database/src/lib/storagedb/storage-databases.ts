import { IDatabase } from "../database";
import { AbstractDatabases, IDatabases } from "../databases";
import { IStorage } from "../storage/storage";
import { StorageDatabase } from "./storage-database";


export class StorageDatabases extends AbstractDatabases implements IDatabases {

    constructor(private storage: IStorage) {
        super();
    }

    //
    // Gets a database by name.
    //   
    database(databaseName: string): IDatabase {
        return new StorageDatabase(this.storage, databaseName);
    }
}
