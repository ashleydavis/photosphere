//
// Provides a sink for adding/updating assets to indexeddb.
//

import React, { createContext, ReactNode, useContext, useEffect, useRef, useState } from "react";
import { IGalleryItem } from "../../lib/gallery-item";
import { IAssetDetails, IGallerySink } from "./gallery-sink";

//
// Use the "Local sink" in a component.
//
export function useLocalGallerySink({ cloudSink }: { cloudSink: IGallerySink }): IGallerySink {

    //
    // Uploads an asset.
    //
    async function uploadAsset(assetId: string, assetType: string, contentType: string, data: Blob): Promise<void> {

        ///todo: save it in indexeddb. Queue for upload to cloud.

        await cloudSink.uploadAsset(assetId, assetType, contentType, data);
    }

    //
    // Adds an asset to the gallery.
    //
    async function addAsset(assetDetails: IAssetDetails): Promise<string> {

        const assetId = await cloudSink.addAsset(assetDetails);

        //todo: add to indexeddb. Queue for upload to cloud.

        return assetId;
    }

    //
    // Updates the configuration of the asset.
    //
    async function updateAsset(assetId: string, assetUpdate: Partial<IGalleryItem>): Promise<void> {

        //todo: update in indexeddb. Queue for upload to cloud.

        await cloudSink.updateAsset(assetId, assetUpdate);
    }

    return {
        addAsset,
        uploadAsset,
        updateAsset,
    };
}
