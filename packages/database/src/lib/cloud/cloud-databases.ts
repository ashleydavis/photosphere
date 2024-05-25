import { IApi } from "../api";
import { IDatabases } from "../databases";
import { ICloudDatabase, CloudDatabase } from "./cloud-database";

export interface ICloudDatabases extends IDatabases {
    //
    // Gets a database by name.
    //   
    database(databaseName: string): ICloudDatabase;
}

export class CloudDatabases implements ICloudDatabases {

    constructor(private api: IApi) {
    }

    //
    // Gets a database by name.
    //   
    database(databaseName: string): ICloudDatabase {
        return new CloudDatabase(databaseName, this.api);
    }
}
