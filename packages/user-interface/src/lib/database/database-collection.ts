//
// A page of records from the database.
//
export interface IRecord {
    _id: string;
}

//
// Implements a collection of records in the database.
//
export interface IDatabaseCollection<RecordT extends IRecord> {
    
    //
    // Sets a new record in the database.
    //
    setOne(record: RecordT): Promise<void>;

    //
    // Gets one record by id.
    //
    getOne(id: string): Promise<RecordT | undefined>;

    //
    // Gets all records from the database.
    //
    getAll(): Promise<RecordT[]>;

    //
    // Gets records from the database that match the requested index.
    //
    getAllByIndex(indexName: string, indexValue: any): Promise<RecordT[]>;

    //
    // Gets the least recent record from the database.
    // This relies on the ids being timestamps in reverse chronological order.
    //
    getLeastRecentRecord(collectionName: string): Promise<[string, RecordT] | undefined>;

    //
    // Deletes a record from the database.
    //
    deleteOne(id: string): Promise<void>;
}
