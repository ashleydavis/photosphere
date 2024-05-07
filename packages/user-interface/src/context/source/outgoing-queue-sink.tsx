//
// Provides a sink that stores outgoing assets in indexeddb and queues them for upload to the cloud.
//

import { IGallerySink } from "./gallery-sink";
import { uuid } from "../../lib/uuid";
import { useIndexeddb } from "../indexeddb-context";
import { ICollectionOps } from "../../def/ops";

//
// Records an asset upload in the outgoing queue.
//
export interface IAssetUploadRecord {
    //
    // ID of the database record.
    //
    _id: string;

    //
    // ID of the collection to upload to.
    //
    collectionId: string;

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
    // Operations to apply to the database.
    //
    collectionOps: ICollectionOps;
}

//
// Use the outgoing queue sink in a component.
//
export function useOutgoingQueueSink(): IGallerySink {

    const { storeRecord } = useIndexeddb();

    //
    // Uploads an asset.
    //
    async function uploadAsset(collectionId: string, assetId: string, assetType: string, contentType: string, data: Blob): Promise<void> {
        await storeRecord<IAssetUploadRecord>("user", "outgoing-asset-upload", {
            _id: uuid(),
            collectionId,
            assetId,
            assetType,
            contentType,
            data,
        });
    }

    //
    // Updates the configuration of the asset.
    //
    async function updateAsset(collectionOps: ICollectionOps): Promise<void> {
        await storeRecord<IAssetUpdateRecord>("user", "outgoing-asset-update", {
            _id: uuid(),
            collectionOps,
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
