//
// Provides a sink that stores outgoing assets in indexeddb and queues them for upload to the cloud.
//

import { IAsset } from "../../def/asset";
import { storeRecord } from "../../lib/indexeddb";
import { IGallerySink } from "./gallery-sink";
import { uuid } from "../../lib/uuid";
import { useIndexeddb } from "../indexeddb-context";

//
// Records an asset upload in the outgoing queue.
//
export interface IAssetUploadRecord {
    //
    // ID of the database record.
    //
    _id: string;

    //
    // ID of the asset.
    //
    assetId: string;

    //
    // Type of the asset.
    //    
    assetType: string;
    
    //
    // Content type of the asset.
    //
    contentType: string;
    
    //
    // Data of the asset.
    //
    data: Blob;
}

//
// Records an asset update in the outgoing queue.
//
export interface IAssetUpdateRecord {
    //
    // ID of the database record.
    //
    _id: string;

    //
    // The asset to update.
    //
    assetId: string;
    
    //
    // The fields of the asset to update.
    //
    assetUpdate: Partial<IAsset>;
}

//
// Use the outgoing queue sink in a component.
//
export function useOutgoingQueueSink(): IGallerySink {

    const { db } = useIndexeddb();

    //
    // Uploads an asset.
    //
    async function uploadAsset(assetId: string, assetType: string, contentType: string, data: Blob): Promise<void> {
        if (db === undefined) {
            throw new Error("Database not open");
        }

        await storeRecord<IAssetUploadRecord>(db, "outgoing-asset-upload", {
            _id: uuid(),
            assetId,
            assetType,
            contentType,
            data,
        });
    }

    //
    // Updates the configuration of the asset.
    //
    async function updateAsset(assetId: string, assetUpdate: Partial<IAsset>): Promise<void> {
        if (db === undefined) {
            throw new Error("Database not open");
        }

        await storeRecord<IAssetUpdateRecord>(db, "outgoing-asset-update", {
            _id: uuid(),
            assetId,
            assetUpdate,
        });
    }

    //
    // Check if asset has already been uploaded with a particular hash.
    //
    async function checkAsset(hash: string): Promise<string | undefined> {       
        return undefined;
    }

    return {
        uploadAsset,
        updateAsset,
        checkAsset,
    };
}
