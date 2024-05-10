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

export interface IAssetOp {
    //
    // The id of the collection to which this operation is applied.
    //
    collectionId: string; 

    //
    // The id of the asset to which operations are applied.
    //
    assetId: string;    

    //
    // The operation to apply to the asset.
    //
    op: IOpSelection;
}

//
// Records an operation against a particular asset.
//
export interface IAssetOpRecord {
    //
    // The date the server received the operation.
    //
    serverTime: string;

    //
    // The client where the operation originated.
    //
    clientId: string;

    //
    // The id of the asset to which the operation is applied.
    //
    assetId: string;

    //
    // The operation that was applied to the asset.
    //
    op: IOpSelection;
}
