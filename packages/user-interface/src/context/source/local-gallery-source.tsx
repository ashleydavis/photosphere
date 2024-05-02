//
// Provides a source of assets for the gallery from indexeddb.
//

import { IGallerySource } from "./gallery-source";
import { useRef } from "react";
import { IGalleryItem } from "../../lib/gallery-item";

//
// Use the "Local source" in a component.
//
export function useLocalGallerySource({ cloudSource }: { cloudSource: IGallerySource }): IGallerySource {

    //
    // A cache entry for a loaded asset.
    //
    interface IAssetCacheEntry {
        //
        // Number of references to this asset.
        //
        numRefs: number;

        //
        // Object URL for the asset.
        //
        objectUrl: string;
    }

    //
    // Caches loaded assets.
    //
    const assetCache = useRef<Map<string, IAssetCacheEntry>>(new Map<string, IAssetCacheEntry>());

    //
    // Retreives assets from the source.
    //
    async function getAssets(): Promise<IGalleryItem[]> {

        //todo: get from indexeddb. No fallback to cloud. Need a separate sync process to replicate cloud metdata to indexeddb.

        return await cloudSource.getAssets();
    }

    //
    // Loads data for an asset.
    //
    function loadAsset(assetId: string, type: string, onLoaded: (objectURL: string) => void): void {

        //todo: load from indexed db, fallback to cloud if asset doesn't exist locally.

        cloudSource.loadAsset(assetId, type, onLoaded);
    }

    //
    // Unloads data for an asset.
    //
    function unloadAsset(assetId: string, type: string): void {
        
        //todo: unload from indexed db.

        cloudSource.unloadAsset(assetId, type);
    }

    return {
        getAssets,
        loadAsset,
        unloadAsset,
    };
}
