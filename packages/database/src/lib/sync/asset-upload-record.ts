import { IAssetData } from "../../defs/asset-data";

//
// Records an asset upload in the outgoing queue.
//
export interface IAssetUploadRecord {
    //
    // ID of the collection to upload to.
    //
    collectionId: string;

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
    assetData: IAssetData;
}