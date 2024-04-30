//
// Interface for the a "source" of assets.
//

import { IGalleryItem } from "../../lib/gallery-item";

export interface IGallerySource {
    //
    // The assets currently loaded.
    //
    assets: IGalleryItem[];

    //
    // Loads data for an asset.
    //
    loadAsset(assetId: string, type: string, onLoaded: (objectURL: string) => void): void;

    //
    // Unloads data for an asset.
    //
    unloadAsset(assetId: string, type: string): void;
}