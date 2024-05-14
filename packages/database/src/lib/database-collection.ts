//
// A page of records from the database.

import { IDatabaseOp } from "../defs/ops";

//
export interface IPage<RecordT> {
    //
    // Array of records in the page.
    //
    records: RecordT[];

    //
    // Continuation token for the next page.
    //
    next?: string;
}

//
// Implements a collection of records in the database.
//
export interface IDatabaseCollection<RecordT = any> {
    //
    // Sets a new record to the database.
    //
    setOne(id: string, record: RecordT): Promise<void>;

    //
    // Gets one record by id.
    //
    getOne(id: string): Promise<RecordT | undefined>;

    //
    // Lists all records in the database.
    //
    listAll(max: number, next?: string): Promise<IPage<string>>;

    //
    // Gets a page of records from the database.
    //
    getAll(max: number, next?: string): Promise<IPage<RecordT>>;

    //
    // Deletes a record from the database.
    //
    deleteOne(id: string): Promise<void>;

    //
    // Returns true if there are no records in the collection.
    //
    none(): Promise<boolean>;

    // 
    // Gets the oldest record in the collection.
    //
    getLeastRecentRecord(): Promise<RecordT | undefined>;
}
