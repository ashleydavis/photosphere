//
// Records the time the last update was read from the server.
//
export interface ILastUpdateRecord {
    //
    // The ID of the record.
    //
    _id: string;

    //
    // The time of the last update.
    //
    lastUpdateTime: string;
}