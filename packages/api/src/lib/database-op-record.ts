//
// Records an operation against a particular database record.

import { IOpSelection } from "./op";

//
export interface IDatabaseOpRecord {
    //
    // The ID of the database op record.
    //
    _id: string;

    //
    // The date the server received the operation.
    //
    serverTime: Date;

    //
    // Records the sequence in which the operation were received.
    //
    sequence: number;

    //
    // The client where the operation originated.
    //
    clientId: string;

    //
    // The name of the database collection to which the operation is applied.
    //
    collectionName: string;

    //
    // The id of the database record to which the operation is applied.
    //
    recordId: string;

    //
    // The operation that was applied to the asset.
    //
    op: IOpSelection;
}
