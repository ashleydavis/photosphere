//
// Provides a source of assets for the gallery from indexeddb.
//

import { IGallerySource } from "./gallery-source";
import { useRef } from "react";
import { IGalleryItem } from "../../lib/gallery-item";

//
// Use the "Local source" in a component.
//
export function useLocalGallerySource({ indexeddbSource, cloudSource }: { indexeddbSource: IGallerySource, cloudSource: IGallerySource }): IGallerySource {
    //
    // Retreives assets from the source.
    //
    async function getAssets(): Promise<IGalleryItem[]> {
        return await indexeddbSource.getAssets();
    }

    //
    // Loads data for an asset.
    //
    async function loadAsset(assetId: string, assetType: string): Promise<string | undefined> {

        const localAsset = await indexeddbSource.loadAsset(assetId, assetType);
        if (localAsset) {
            return localAsset;
        }
        
        // Fallback to cloud.
        return await cloudSource.loadAsset(assetId, assetType);        
    }

    //
    // Unloads data for an asset.
    //
    function unloadAsset(assetId: string, assetType: string): void {
        indexeddbSource.unloadAsset(assetId, assetType);
        cloudSource.unloadAsset(assetId, assetType);
    }

    return {
        getAssets,
        loadAsset,
        unloadAsset,
    };
}
