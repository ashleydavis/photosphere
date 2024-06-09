import { IDatabaseOp } from "defs";

//
// Records an asset update in the outgoing queue.
//
export interface IAssetUpdateRecord {
    //
    // Operations to apply to the database.
    //
    ops: IDatabaseOp[];
}
