import { IOpSelection } from "./op";

export interface IDatabaseOp {
    //
    // The name of the database collection to which the operation is applied.
    //
    collectionName: string;

    //
    // The set to apply the operation to.
    //
    setId: string; //todo: want to get rid of this.

    //
    // The id of the asset to which operations are applied.
    //
    recordId: string;

    //
    // The operation to apply to the asset.
    //
    op: IOpSelection;
}