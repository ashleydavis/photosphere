
import { IAssetData } from "../defs/asset-data";

//
// Loads assets from a particular location.
//
export interface IAssetSource {

    //
    // Set to true when the source is initialised.
    //
    isInitialised: boolean;

    //
    // Loads data for an asset.
    //
    loadAsset(collectionId: string, assetId: string, assetType: string): Promise<IAssetData | undefined>;
}