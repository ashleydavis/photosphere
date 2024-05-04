//
// Provides a source of assets for the gallery from indexeddb.
//

import { IGallerySource } from "./gallery-source";
import { useEffect, useRef } from "react";
import { IGalleryItem } from "../../lib/gallery-item";
import { useApi } from "../api-context";
import { getAllRecords, getAsset, openDatabase } from "../../lib/indexeddb";

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

    const db = useRef<IDBDatabase | undefined>(undefined);

    useEffect(() => {

        async function openDb() {
            db.current = await openDatabase();
        }

        openDb()
            .catch(err => {
                console.error(`Failed to open indexeddb:`);
                console.error(err);
            });

        return () => {
            if (db.current) {
                db.current.close();
                db.current = undefined;
            }
        };
    });

    //
    // Retreives assets from the source.
    //
    async function getAssets(): Promise<IGalleryItem[]> {
        if (db.current === undefined) {
            return [];
        }

        return await getAllRecords<IGalleryItem>(db.current, "metadata");
    }

    //
    // Loads data for an asset.
    //
    async function loadAsset(assetId: string, assetType: string): Promise<string | undefined> {
        if (db.current === undefined) {
            return undefined;
        }

        const key = `${assetType}/${assetId}`;
        const existingCacheEntry = assetCache.current.get(key);
        if (existingCacheEntry) {
            existingCacheEntry.numRefs += 1;
            return existingCacheEntry.objectUrl;
        }

        const assetData = await getAsset(db.current, assetType, assetId)
        if (!assetData) {
            console.error(`Asset not found: ${assetType}:${assetId}`);
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
