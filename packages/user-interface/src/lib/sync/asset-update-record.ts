import { IDatabaseOp } from "defs";

//
// Records an asset update in the outgoing queue.
//
export interface IAssetUpdateRecord {
    //
    // ID of the record.
    //
    _id: string;

    //
    // Operations to apply to the database.
    //
    ops: IDatabaseOp[];
}
