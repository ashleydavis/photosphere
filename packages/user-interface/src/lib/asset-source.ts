
import { IAsset } from "defs";
import { IAssetData } from "../def/asset-data";

//
// Loads assets from a particular location.
//
export interface IAssetSource {

    //
    // Loads metadata for all assets.
    //
    loadAssets(collectionId: string): Promise<IAsset[]>;

    //
    // Maps a hash to the assets already uploaded.
    //
    mapHashToAssets(collectionId: string, hash: string): Promise<string[]>;
    
    //
    // Loads data for an asset.
    //
    loadAsset(collectionId: string, assetId: string, assetType: string): Promise<IAssetData | undefined>;
}