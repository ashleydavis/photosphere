
import { IAsset } from "../defs/asset";
import { IAssetData } from "../defs/asset-data";
import { IPage } from "../defs/page";

//
// Loads assets from a particular location.
//
export interface IAssetSource {

    //
    // Set to true when the source is initialised.
    //
    isInitialised: boolean;

    //
    // Loads metadata for all assets.
    //
    loadAssets(collectionId: string, max: number, next?: string): Promise<IPage<IAsset>>;

    //
    // Maps a hash to the assets already uploaded.
    //
    mapHashToAssets(collectionId: string, hash: string): Promise<string[]>;
    
    //
    // Loads data for an asset.
    //
    loadAsset(collectionId: string, assetId: string, assetType: string): Promise<IAssetData | undefined>;
}