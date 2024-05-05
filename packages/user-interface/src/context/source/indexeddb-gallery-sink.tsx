//
// Provides a sink for adding/updating assets to indexeddb.
//

import React, { createContext, ReactNode, useContext, useEffect, useRef } from "react";
import { IGalleryItem } from "../../lib/gallery-item";
import { IGallerySink } from "./gallery-sink";
import { getRecord, storeAsset, storeRecord } from "../../lib/indexeddb";
import { IAsset } from "../../def/asset";
import { useIndexeddb } from "../indexeddb-context";

//
// Use the "Indexeddb sink" in a component.
//
export function useIndexeddbGallerySink(): IGallerySink {

    const { db } = useIndexeddb();

    //
    // Uploads an asset.
    //
    async function uploadAsset(assetId: string, assetType: string, contentType: string, assetData: Blob): Promise<void> {
        if (db === undefined) {
            throw new Error("Database not open");
        }

        await storeAsset(db, assetType, assetId, {
            contentType,
            data: assetData,        
        });
    }

    //
    // Maps hashes to assets.
    //
    interface IHashRecord {
        //
        // ID of the record.
        //
        _id: string;

        //
        // Asset ids that map to this hash.
        //
        assetIds: string[];
    }

    //
    // Updates the configuration of the asset.
    //
    async function updateAsset(assetId: string, assetUpdate: Partial<IAsset>): Promise<void> {
        if (db === undefined) {
            throw new Error("Database not open");
        }

        let asset = await getRecord<any>(db, "metadata", assetId);
        if (!asset) {
            asset = {};
        }

        await storeRecord<any>(db, "metadata", {
            _id: assetId,
            ...asset,
            ...assetUpdate,
        });
    }

    //
    // Check that asset that has already been uploaded with a particular hash.
    //
    async function checkAsset(hash: string): Promise<string | undefined> {
        if (db === undefined) {
            throw new Error("Database not open");
        }

        const hashRecord = await getRecord<IHashRecord>(db, "hashes", hash);
        if (!hashRecord) {
            return undefined;
        }

        if (hashRecord.assetIds.length < 1) { 
            return undefined;
        }

        return hashRecord.assetIds[0]; //TODO: This make this cope with hash collisions.
    }

    return {
        uploadAsset,
        updateAsset,
        checkAsset,
    };
}
