//
// Provides a source of assets for the gallery from the cloud.
//

import React, { createContext, ReactNode, useContext, useEffect, useReducer, useRef, useState } from "react";
import { IGallerySource } from "./gallery-source";
import { useApi } from "../api-context";
import { IGalleryItem } from "../../lib/gallery-item";
import { IAssetDetails, IGallerySink } from "./gallery-sink";
import dayjs from "dayjs";

export interface ICloudGallerySourceContext extends IGallerySource, IGallerySink {
    //
    // Loads assets into the gallery.
    //
    loadAssets(): Promise<void>;
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
    // Loads data for an asset.
    //
    function loadAsset(assetId: string, type: string, onLoaded: (objectURL: string) => void): void {
        const key = `${type}/${assetId}`;
        const existingCacheEntry = assetCache.current.get(key);
        if (existingCacheEntry) {
            existingCacheEntry.numRefs += 1;
            onLoaded(existingCacheEntry.objectUrl);
            return;
        }

        api.getAsset(assetId, type)
            .then(assetBlob => {
                const objectUrl = URL.createObjectURL(assetBlob);
                assetCache.current.set(key, { numRefs: 1, objectUrl });
                onLoaded(objectUrl);
            })
            .catch(err => {
                console.error(`Failed to load asset ${type}:${assetId}`);
                console.error(err);
            });
    }

    //
    // Unloads data for an asset.
    //
    function unloadAsset(assetId: string, type: string): void {
        const key = `${type}/${assetId}`;
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

    //
    // Uploads an asset.
    //
    async function uploadAsset(assetId: string, assetType: string, contentType: string, data: Blob): Promise<void> {
        await api.uploadSingleAsset(assetId, assetType, contentType, data);
    }

    //
    // Adds an asset to the gallery.
    //
    async function addAsset(assetDetails: IAssetDetails): Promise<string> {

        const assetId = await api.uploadAssetMetadata(assetDetails);

        const sortDate = assetDetails.photoDate || assetDetails.fileDate;
        const galleryItem: IGalleryItem = {
            _id: assetId,
            width: assetDetails.width,
            height: assetDetails.height,
            origFileName: assetDetails.fileName,
            hash: assetDetails.hash,
            location: assetDetails.location,
            fileDate: assetDetails.fileDate,
            photoDate: assetDetails.photoDate,
            sortDate,
            group: dayjs(sortDate).format("MMM, YYYY"),
            uploadDate: dayjs(new Date()).format(),
            properties: assetDetails.properties,
            labels: assetDetails.labels,
            description: "",
        };

        setAssets([ galleryItem, ...assets ]);

        return assetId;
    }

    //
    // Updates the configuration of the asset.
    //
    async function updateAsset(assetIndex: number, assetUpdate: Partial<IGalleryItem>): Promise<void> {
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

        await api.updateAssetMetadata(assets[assetIndex]._id, assetUpdate);
    }    
        
    const value: ICloudGallerySourceContext = {
        loadAssets,
        assets,
        addAsset,
        loadAsset,
        unloadAsset,
        uploadAsset,
        updateAsset,
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

