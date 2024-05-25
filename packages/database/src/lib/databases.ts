import { IDatabaseOp } from "../defs/ops";
import { IDatabase } from "./database";

export interface IDatabases {
    //
    // Gets a database by nane.
    //
    database(databaseName: string): IDatabase;
}
