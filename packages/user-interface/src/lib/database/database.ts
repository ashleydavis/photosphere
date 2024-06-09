import { IDatabaseCollection, IRecord } from "./database-collection";

//
// Implements a database.
//
export interface IDatabase {
    //
    // Gets a database collection by name.
    //
    collection<RecordT extends IRecord>(name: string): IDatabaseCollection<RecordT>;
}
