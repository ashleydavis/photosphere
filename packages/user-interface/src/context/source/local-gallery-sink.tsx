//
// Provides a sink for adding/updating assets to indexeddb.
//

import { IDatabaseOp } from "database";
import { IAssetData } from "../../def/asset-data";
import { IGallerySink } from "./gallery-sink";
import { IPersistentQueue } from "../persistent-queue";
import { IAssetUploadRecord } from "../../def/asset-upload-record";
import { IAssetUpdateRecord } from "../../def/asset-update-record";

export interface IProps { 
    indexeddbSink: IGallerySink;

    //
    // Queues outgoing asset uploads.
    //
    outgoingAssetUploadQueue: IPersistentQueue<IAssetUploadRecord>;

    //
    // Queues outgoing asset updates.
    //
    outgoingAssetUpdateQueue: IPersistentQueue<IAssetUpdateRecord>;
};

//
// Use the "Local sink" in a component.
//
export function useLocalGallerySink({ indexeddbSink, outgoingAssetUploadQueue, outgoingAssetUpdateQueue }: IProps): IGallerySink {

    //
    // Stores an asset.
    //
    async function storeAsset(collectionId: string, assetId: string, assetType: string, assetData: IAssetData): Promise<void> {
        // 
        // Store the asset locally.
        //
        await indexeddbSink.storeAsset(collectionId, assetId, assetType, assetData);

        // 
        // Queue the asset for upload to the cloud.
        //
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
        //
        // Update the asset locally.
        //
        await indexeddbSink.submitOperations(ops);

        //
        // Queue the update for upload to the cloud.
        //
        await outgoingAssetUpdateQueue.add({
            ops,
        });
    }

    //
    // Check if asset has already been uploaded with a particular hash.
    //
    async function checkAsset(collectionId: string, hash: string): Promise<string | undefined> { //todo: should this move to the cloud source?
        return await indexeddbSink.checkAsset(collectionId, hash);

        //todo: should this check the cloud source?
    }

    return {
        storeAsset,
        submitOperations,
        checkAsset,
    };
}
