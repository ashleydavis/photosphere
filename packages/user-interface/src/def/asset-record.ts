import { IAssetData } from "database";

//
// Specifies the local record for an asset.
// 
export interface IAssetRecord {
    //
    // The ID of the asset.
    //
    _id: string;

    //
    // The date the asset was stored.
    //
    storeDate: Date;

    //
    // Data for the asset.
    //
    assetData: IAssetData;
}
