import { IAssetSink } from "../asset-sink";
import { IDatabases } from "../databases";
import { IAssetUpdateRecord } from "./asset-update-record";
import { IAssetUploadRecord } from "./asset-upload-record";
import { IPersistentQueue } from "./persistent-queue";

interface IProps {
    //
    // Sink for sending assets and updates to the cloud.
    //
    cloudSink: IAssetSink;

    //
    // Interface to the cloud databases.
    //
    cloudDatabases: IDatabases;

    //
    // Queue of outgoing asset uploads.
    //
    outgoingAssetUploadQueue: IPersistentQueue<IAssetUploadRecord>;

    //
    // Queue of outgoing asset updates.
    //
    outgoingAssetUpdateQueue: IPersistentQueue<IAssetUpdateRecord>;
}

//
// Send outgoing asset uploads and updates to the cloud.
//
export async function syncOutgoing({ cloudSink, cloudDatabases, outgoingAssetUploadQueue, outgoingAssetUpdateQueue }: IProps): Promise<void> {
    //
    // Flush the queue of outgoing asset uploads.
    //
    while (true) {
        const outgoingUpload = await outgoingAssetUploadQueue.getNext();
        if (!outgoingUpload) {
            break;
        }

        await cloudSink.storeAsset(outgoingUpload.collectionId, outgoingUpload.assetId, outgoingUpload.assetType, outgoingUpload.assetData);
        await outgoingAssetUploadQueue.removeNext();

        console.log(`Processed outgoing upload: ${outgoingUpload.collectionId}/${outgoingUpload.assetType}/${outgoingUpload.assetId}`);
    }

    //
    // Flush the queue of outgoing asset updates.
    //
    while (true) {
        const outgoingUpdate = await outgoingAssetUpdateQueue.getNext();
        if (!outgoingUpdate) {
            break;
        }

        await cloudDatabases.submitOperations(outgoingUpdate.ops);
        await outgoingAssetUpdateQueue.removeNext();

        console.log(`Processed outgoing updates:`);
        for (const op of outgoingUpdate.ops) {
            console.log(`  ${op.databaseName}/${op.collectionName}/${op.recordId}`);
        }
    }
}    