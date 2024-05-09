//
// Provides a sink that stores outgoing assets in indexeddb and queues them for upload to the cloud.
//

import { IGallerySink } from "./gallery-sink";
import { uuid } from "../../lib/uuid";
import { useIndexeddb } from "../indexeddb-context";
import { ICollectionOps } from "../../def/ops";
import { IAssetData } from "../../def/asset-data";

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
    // Type of the asset.
    //    
    assetType: string;
    
    //
    // Data of the asset.
    //
    assetData: IAssetData;
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
    // Stores an asset.
    //
    async function storeAsset(collectionId: string, assetType: string, assetData: IAssetData): Promise<void> {
        await storeRecord<IAssetUploadRecord>("user", "outgoing-asset-upload", {
            _id: uuid(),
            collectionId,
            assetType,
            assetData,
        });
    }

    //
    // Submits operations to change the database.
    //
    async function submitOperations(collectionOps: ICollectionOps): Promise<void> {
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
        storeAsset,
        submitOperations,
        checkAsset,
    };
}
