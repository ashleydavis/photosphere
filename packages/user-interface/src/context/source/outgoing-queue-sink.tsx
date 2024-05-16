//
// Provides a sink that stores outgoing assets in indexeddb and queues them for upload to the cloud.
//

import { IGallerySink } from "./gallery-sink";
import { IAssetData } from "../../def/asset-data";
import { IDatabaseOp } from "database";
import { IPersistentQueue } from "../persistent-queue";

//
// Records an asset upload in the outgoing queue.
//
export interface IAssetUploadRecord {
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
    // Data of the asset.
    //
    assetData: IAssetData;
}

//
// Records an asset update in the outgoing queue.
//
export interface IAssetUpdateRecord {
    //
    // Operations to apply to the database.
    //
    ops: IDatabaseOp[];
}

export interface IProps {
    //
    // Queues outgoing asset uploads.
    //
    outgoingAssetUploadQueue: IPersistentQueue<IAssetUploadRecord>;

    //
    // Queues outgoing asset updates.
    //
    outgoingAssetUpdateQueue: IPersistentQueue<IAssetUpdateRecord>;
}

//
// Use the outgoing queue sink in a component.
//
export function useOutgoingQueueSink({ outgoingAssetUploadQueue, outgoingAssetUpdateQueue }: IProps): IGallerySink {

    //
    // Stores an asset.
    //
    async function storeAsset(collectionId: string, assetId: string, assetType: string, assetData: IAssetData): Promise<void> {
        await outgoingAssetUploadQueue.add({
            collectionId,
            assetId,
            assetType,
            assetData,
         });
    }

    //
    // Submits operations to change the database.
    //
    async function submitOperations(ops: IDatabaseOp[]): Promise<void> {
        await outgoingAssetUpdateQueue.add({
            ops,
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
