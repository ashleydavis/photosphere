//
// Provides a source of assets for the gallery from the cloud.
//

import React, { createContext, ReactNode, useContext, useEffect, useRef, useState } from "react";
import { useApi } from "../api-context";
import { IGalleryItem } from "../../lib/gallery-item";
import { IAssetDetails, IGallerySink } from "./gallery-sink";
import { uuid } from "../../lib/uuid";

export interface ICloudGallerySinkContext extends IGallerySink {
}

const CloudGallerySinkContext = createContext<ICloudGallerySinkContext | undefined>(undefined);

export interface ICloudGallerySinkContextProviderProps {
    children: ReactNode | ReactNode[];
}

export function CloudGallerySinkContextProvider({ children }: ICloudGallerySinkContextProviderProps) {

    //
    // Interface to the backend.
    //
    const api = useApi();

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

    const value: ICloudGallerySinkContext = {
        addAsset,
        uploadAsset,
        updateAsset,
    };

    return (
        <CloudGallerySinkContext.Provider value={value} >
            {children}
        </CloudGallerySinkContext.Provider>
    );
}

//
// Use the "Cloud sink" in a component.
//
export function useCloudGallerySink(): ICloudGallerySinkContext {
    const context = useContext(CloudGallerySinkContext);
    if (!context) {
        throw new Error(`"Cloud sink" context is not set! Add CloudGallerySinkContextProvider to the component tree.`);
    }
    return context;
}

