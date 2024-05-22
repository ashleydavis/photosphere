//
// Records last update ids for each collection in the local database.
//
export interface IUpdateIdRecord {
    //
    // The ID of the record.
    //
    _id: string;

    //
    // The last update id for the collection.
    //
    lastUpdateId: string;
}