//
// Provides a source of assets for the gallery from indexeddb.
//

import { IGallerySource } from "./gallery-source";
import { useEffect, useRef } from "react";
import { IGalleryItem } from "../../lib/gallery-item";
import { useApi } from "../api-context";
import { useIndexeddb } from "../indexeddb-context";
import { IUser } from "../../def/user";
import { IAssetData } from "../../def/asset-data";

//
// Use the "Indexeddb source" in a component.
//
export function useIndexeddbGallerySource(): IGallerySource {

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

        //
        // The content type for the asset.
        //
        contentType: string;
    }

    //
    // Caches loaded assets.
    //
    const assetCache = useRef<Map<string, IAssetCacheEntry>>(new Map<string, IAssetCacheEntry>());

    const { getAllRecords, getRecord } = useIndexeddb();

    //
    // Loads the user's details.
    //
    async function getUser(): Promise<IUser | undefined> {
        const user = await getRecord<IUser>("user", "user", "config");
        if (!user) {
            return undefined;
        }

        return user;
    }

    //
    // Retreives assets from the source.
    //
    async function getAssets(collectionId: string): Promise<IGalleryItem[]> {
        return await getAllRecords<IGalleryItem>(`collection-${collectionId}`, "metadata");
    }

    //
    // Loads data for an asset.
    //
    async function loadAsset(collectionId: string, assetId: string, assetType: string): Promise<string | undefined> {
        const key = `${collectionId}/${assetType}/${assetId}`;
        const existingCacheEntry = assetCache.current.get(key);
        if (existingCacheEntry) {
            existingCacheEntry.numRefs += 1;
            return existingCacheEntry.objectUrl;
        }

        const assetData = await getRecord<IAssetData>(`collection-${collectionId}`, assetType, assetId);
        if (!assetData) {
            return undefined;
        }

        const objectUrl = URL.createObjectURL(assetData.data);
        assetCache.current.set(key, { 
            numRefs: 1, 
            objectUrl, 
            contentType: assetData.contentType,
        });
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
        isInitialised: true, // Indexedb is always considered online.
        getUser,
        getAssets,
        loadAsset,
        unloadAsset,
    };
}
