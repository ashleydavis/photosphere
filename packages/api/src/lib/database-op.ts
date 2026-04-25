import { IOpSelection } from "./op";

export interface IDatabaseOp {
    //
    // The database the operation is applied to.
    //
    databaseId: string;

    //
    // The name of the database collection to which the operation is applied.
    //
    collectionName: string;

    //
    // The id of the asset to which operations are applied.
    //
    recordId: string;

    //
    // The operation to apply to the asset.
    //
    op: IOpSelection;
}