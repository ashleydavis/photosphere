//
// Provides a source of assets for the gallery from the cloud.
//

import { IGallerySource } from "./gallery-source";
import { useApi } from "../api-context";
import { useRef } from "react";
import { IGalleryItem } from "../../lib/gallery-item";
import { IUser } from "../../def/user";

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
    // Loads the user's details.
    //
    async function getUser(): Promise<IUser | undefined> {
        return await api.getUser();
    }

    //
    // Retreives assets from the source.
    //
    async function getAssets(collectionId: string): Promise<IGalleryItem[]> {
        return await api.getAssets(collectionId);
    }

    //
    // Loads data for an asset.
    //
    async function loadAsset(collectionId: string, assetId: string, assetType: string): Promise<string | undefined> {
        const key = `${assetType}/${assetId}`;
        const existingCacheEntry = assetCache.current.get(key);
        if (existingCacheEntry) {
            existingCacheEntry.numRefs += 1;
            return existingCacheEntry.objectUrl;
        }

        const assetBlob = await api.getAsset(collectionId, assetId, assetType);
        const objectUrl = URL.createObjectURL(assetBlob);
        assetCache.current.set(key, { numRefs: 1, objectUrl });
        return objectUrl;
    }

    //
    // Unloads data for an asset.
    //
    function unloadAsset(collectionId: string, assetId: string, assetType: string): void {
        const key = `${collectionId}-${assetType}/${assetId}`;
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
        isInitialised: api.isInitialised,
        getUser,
        getAssets,
        loadAsset,
        unloadAsset,
    };
}
