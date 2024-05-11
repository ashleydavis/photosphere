//
// An operation to apply to a database record.
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
// An operation to set a field on a database record.
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

export interface IDatabaseOp {
    //
    // The name of the database to which this operation is applied.
    //
    databaseName: string; 

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

//
// Records an operation against a particular database record.
//
export interface IDatabaseOpRecord {
    //
    // The date the server received the operation.
    //
    serverTime: string;

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
