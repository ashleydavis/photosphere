import { IApi } from "../api";
import { IDatabase } from "../database";
import { ICloudDatabaseCollection, CloudDatabaseCollection } from "./cloud-database-collection";

export interface ICloudDatabase extends IDatabase {
}

//
// Implements a database.
//
export class CloudDatabase implements ICloudDatabase {
    constructor(private databaseName: string, private api: IApi) {
    }

    //
    // Gets a database collection by name.
    //
    collection<RecordT>(collectionName: string): ICloudDatabaseCollection<RecordT> {
        return new CloudDatabaseCollection<RecordT>(this.databaseName, collectionName, this.api);
    }
}
