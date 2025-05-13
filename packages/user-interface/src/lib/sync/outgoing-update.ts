import { IDatabaseOp } from "defs";

//
// Records an asset upload in the outgoing queue.
//
export interface IAssetUploadRecord {
    //
    // The type of the record.
    //
    type: "upload";

    //
    // ID of the collection to upload to.
    //
    setId: string;

    //
    // ID of the asset.
    //
    assetId: string;

    //
    // Type of the asset.
    //    
    assetType: string;
    
    //
    // Data of the asset.
    //
    assetData: Blob;
}

//
// Records an asset update in the outgoing queue.
//
export interface IAssetUpdateRecord {
    //
    // The type of the record.
    //
    type: "update";

    //
    // Operations to apply to the database.
    //
    ops: IDatabaseOp[];
}

export type IOutgoingUpdate = IAssetUploadRecord | IAssetUpdateRecord;