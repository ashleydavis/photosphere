//
// Provides a source of assets for the gallery from the cloud.
//

import React, { createContext, ReactNode, useContext, useEffect, useReducer, useRef, useState } from "react";
import { IGallerySourceContext } from "./gallery-source-context";
import { useApi } from "../api-context";
import { IGalleryItem } from "../../lib/gallery-item";
import { loadImageAsObjectURL, unloadObjectURL } from "../../lib/image";

export interface ICloudGallerySourceContext extends IGallerySourceContext {
    //
    // Loads assets into the gallery.
    //
    loadAssets(): Promise<void>;

    //
    // Adds an asset to the gallery.
    //
    addAsset(asset: IGalleryItem): void;
}

const CloudGallerySourceContext = createContext<ICloudGallerySourceContext | undefined>(undefined);

export interface ICloudGallerySourceContextProviderProps {
    children: ReactNode | ReactNode[];
}

export function CloudGallerySourceContextProvider({ children }: ICloudGallerySourceContextProviderProps) {

    //
    // Interface to the backend.
    //
    const api = useApi();
    
    //
    // Assets that have been loaded from the backend.
    //
    const [ assets, setAssets ] = useState<IGalleryItem[]>([]);

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
    // Resets the gallery when the search text changes.
    //
    useEffect(() => {
        if (api.isInitialised) {
            loadAssets();
        }
    }, [api.isInitialised]);

    //
    // Loads assets into the gallery.
    //
    async function loadAssets(): Promise<void> {
        const newAssets = await api.getAssets();
        setAssets(newAssets);
    }

    //
    // Adds an asset to the gallery.
    //
    function addAsset(asset: IGalleryItem): void {
        setAssets([ asset, ...assets ]);
    }

    //
    // Updates the configuration of the asset.
    //
    function updateAsset(assetIndex: number, assetUpdate: Partial<IGalleryItem>): void {
        setAssets(prevAssets => {
            const newAsset = {
                ...prevAssets[assetIndex],
                ...assetUpdate,
            };
            return [
                ...prevAssets.slice(0, assetIndex),
                newAsset,
                ...prevAssets.slice(assetIndex + 1),
            ];        
        });
    }

    //
    // Loads data for an asset.
    //
    function loadAsset(assetId: string, onLoaded: (objectURL: string) => void): void {
        const existingCacheEntry = assetCache.current.get(assetId);
        if (existingCacheEntry) {
            existingCacheEntry.numRefs += 1;
            onLoaded(existingCacheEntry.objectUrl);
            return;
        }

        const url = api.makeUrl(`/thumb?id=${assetId}`);
        loadImageAsObjectURL(url)
            .then(objectUrl => {                
                assetCache.current.set(assetId, { numRefs: 1, objectUrl });
                onLoaded(objectUrl);
            });
    }

    //
    // Unloads data for an asset.
    //
    function unloadAsset(assetId: string): void {
        const cacheEntry = assetCache.current.get(assetId);
        if (cacheEntry) {            
            if (cacheEntry.numRefs === 1) {
                unloadObjectURL(cacheEntry.objectUrl);
                assetCache.current.delete(assetId);
            }
            else {
                cacheEntry.numRefs -= 1;
            }
        }
    }

    const value: ICloudGallerySourceContext = {
        loadAssets,
        assets,
        addAsset,
        updateAsset,
        loadAsset,
        unloadAsset,
    };
    
    return (
        <CloudGallerySourceContext.Provider value={value} >
            {children}
        </CloudGallerySourceContext.Provider>
    );
}

//
// Use the "Cloud source" in a component.
//
export function useCloudGallerySource(): ICloudGallerySourceContext {
    const context = useContext(CloudGallerySourceContext);
    if (!context) {
        throw new Error(`"Cloud source" context is not set! Add CloudGallerySourceContextProvider to the component tree.`);
    }
    return context;
}

