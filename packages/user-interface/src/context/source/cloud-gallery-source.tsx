//
// Provides a source of assets for the gallery from the cloud.
//

import { IGallerySource } from "./gallery-source";
import { useApi } from "../api-context";
import { useRef } from "react";
import { IGalleryItem } from "../../lib/gallery-item";

//
// Use the "Cloud source" in a component.
//
export function useCloudGallerySource(): IGallerySource {

    //
    // Interface to the backend.
    //
    const api = useApi();

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
        return await api.getAssets();
    }

    //
    // Loads data for an asset.
    //
    async function loadAsset(assetId: string, assetType: string): Promise<string | undefined> {
        const key = `${assetType}/${assetId}`;
        const existingCacheEntry = assetCache.current.get(key);
        if (existingCacheEntry) {
            existingCacheEntry.numRefs += 1;
            return existingCacheEntry.objectUrl;
        }

        const assetBlob = await api.getAsset(assetId, assetType);
        const objectUrl = URL.createObjectURL(assetBlob);
        assetCache.current.set(key, { numRefs: 1, objectUrl });
        return objectUrl;
    }

    //
    // Unloads data for an asset.
    //
    function unloadAsset(assetId: string, assetType: string): void {
        const key = `${assetType}/${assetId}`;
        const cacheEntry = assetCache.current.get(key);
        if (cacheEntry) {
            if (cacheEntry.numRefs === 1) {
                URL.revokeObjectURL(cacheEntry.objectUrl);
                assetCache.current.delete(key);
            }
            else {
                cacheEntry.numRefs -= 1;
            }
        }
    }

    return {
        getAssets,
        loadAsset,
        unloadAsset,
    };
}
