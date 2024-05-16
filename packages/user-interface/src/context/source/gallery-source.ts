//
// Interface for the a "source" of assets.
//

import { IAsset } from "../../def/asset";
import { IAssetData } from "../../def/asset-data";
import { IUser } from "../../def/user";

export interface IGallerySource {

    //
    // Set to true when the source is initialised.
    //
    isInitialised: boolean;

    //
    // Loads the user's details.
    //
    getUser(): Promise<IUser | undefined>;

    //
    // Retreives assets from the source.
    //
    getAssets(collectionId: string): Promise<IAsset[]>;

    //
    // Loads data for an asset.
    //
    loadAsset(collectionId: string, assetId: string, assetType: string): Promise<IAssetData | undefined>;

    //
    // Gets the assets already uploaded with a particular hash.
    //
    checkAssets(collectionId: string, hash: string): Promise<string[] | undefined>;
}