//
// A page of records from the database.
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
