import { IDatabaseCollection } from "./database-collection";

//
// Implements a database.
//
export interface IDatabase {
    //
    // Gets a database collection by name.
    //
    collection<RecordT = any>(name: string): IDatabaseCollection<RecordT>;
}
