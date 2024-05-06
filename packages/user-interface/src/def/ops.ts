
//
// An operation to apply to an asset.
//
export interface IOp {
    //
    // The type of operation:
    //  - Sets the value of a field.
    //  - Pushs a value into an array.
    //  - Pulls a value from an array.
    //
    type: "set" | "push" | "pull";
}

//
// An operation to set a field on an asset.
//
export interface ISetOp extends IOp {
    //
    // The type of operation.
    //
    type: "set";

    //
    // The fields/values to set.
    //
    fields: {
        [field: string]: any;
    };
}

//
// An operation to push a value into an array.
//
export interface IPushOp extends IOp {
    //
    // The type of operation.
    //
    type: "push";

    //
    // The field to push to.
    //
    field: string;

    //
    // The value to push.
    //
    value: any;
}

//
// An operation to pull a value from an array.
//
export interface IPullOp extends IOp {
    //
    // The type of operation.
    //
    type: "pull";

    //
    // The field to pull from.
    //
    field: string;

    //
    // The value to pull.
    //
    value: any;
}

//
// Specifies the range of possible operations.
//
export type IOpSelection = ISetOp | IPushOp | IPullOp;

//
// A set of operations to apply to a particular asset.
//
export interface IAssetOps {
    //
    // The id of the asset to which operations are applied.
    //
    id: string;

    //
    // Operations to apply to this asset.
    //
    ops: IOpSelection[];
}

//
// A set of operations to apply to a particular collection.
//
export interface ICollectionOps {
    //
    // The id of the collection to which operations are applied.
    //
    id: string; 

    //
    // Operations to apply to assets in the collection.
    //
    ops: IAssetOps[];
}

//
// A set of operations to apply to the database.
//
export interface IDbOps {
    //
    // Operations to apply to collections in the database.
    //
    ops: ICollectionOps[];
}
