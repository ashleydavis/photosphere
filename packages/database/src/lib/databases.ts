import { IDatabase } from "./database";

export interface IDatabases {
    //
    // Gets a database by nane.
    //
    database(databaseName: string): Promise<IDatabase>;
}