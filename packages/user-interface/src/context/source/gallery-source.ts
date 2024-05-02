//
// Interface for the a "source" of assets.
//

import { IGalleryItem } from "../../lib/gallery-item";

export interface IGallerySource {

    //
    // Retreives assets from the source.
    //
    getAssets(): Promise<IGalleryItem[]>;

    //
    // Loads data for an asset.
    //
    loadAsset(assetId: string, assetType: string, onLoaded: (objectURL: string) => void): void;

    //
    // Unloads data for an asset.
    //
    unloadAsset(assetId: string, assetType: string): void;
}