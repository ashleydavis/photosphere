
//
// Records an asset update in the outgoing queue.

import { IDatabaseOp } from "database";

//
export interface IAssetUpdateRecord {
    //
    // Operations to apply to the database.
    //
    ops: IDatabaseOp[];
}
