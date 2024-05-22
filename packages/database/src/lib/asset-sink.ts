import { IAssetData } from "../defs/asset-data";

//
// Stores assets to a particular location.
//
export interface IAssetSink {
    //
    // Stores an asset.
    //
    storeAsset(collectionId: string, assetId: string, assetType: string, assetData: IAssetData): Promise<void>;
}