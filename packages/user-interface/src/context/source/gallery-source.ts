//
// Interface for the a "source" of assets.
//

import { IAsset } from "../../def/asset";
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
    loadAsset(collectionId: string, assetId: string, assetType: string): Promise<string | undefined>;

    //
    // Unloads data for an asset.
    //
    unloadAsset(collectionId: string, assetId: string, assetType: string): void;
}