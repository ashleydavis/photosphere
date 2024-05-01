//
// Provides a source of assets for the gallery from the cloud.
//

import React, { createContext, ReactNode, useContext, useEffect, useRef, useState } from "react";
import { IGallerySource } from "./gallery-source";
import { useApi } from "../api-context";
import { IGalleryItem } from "../../lib/gallery-item";
import { IAssetDetails, IGallerySink } from "./gallery-sink";
import { uuid } from "../../lib/uuid";

export interface ICloudGallerySourceContext extends IGallerySource, IGallerySink {
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

        const assetId = uuid();

        await api.submitOperations([
            {
                id: assetId,
                ops: [
                    {
                        type: "set",
                        fields: {
                            fileName: assetDetails.fileName,
                            width: assetDetails.width,
                            height: assetDetails.height,
                            hash: assetDetails.hash,
                            properties: assetDetails.properties,
                            location: assetDetails.location,
                            fileDate: assetDetails.fileDate,
                            photoDate: assetDetails.photoDate,
                            labels: assetDetails.labels,
                        },
                    },
                ],
            },
        ]);

        return assetId;
    }

    //
    // Updates the configuration of the asset.
    //
    async function updateAsset(assetId: string, assetUpdate: Partial<IGalleryItem>): Promise<void> {
        await api.submitOperations([
            {
                id: assetId,
                ops: [
                    {
                        type: "set",
                        fields: assetUpdate, //TODO: Should use push/pull for labels.
                    }
                ],
            },        
        ]);

    }

    const value: ICloudGallerySourceContext = {
        getAssets,
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

