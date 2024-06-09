import { IApi } from "../../context/api-context";
import { IAssetUpdateRecord } from "./asset-update-record";
import { IAssetUploadRecord } from "./asset-upload-record";
import { IPersistentQueue } from "./persistent-queue";

interface IProps {

    //
    // Queue of outgoing asset uploads.
    //
    outgoingAssetUploadQueue: IPersistentQueue<IAssetUploadRecord>;

    //
    // Queue of outgoing asset updates.
    //
    outgoingAssetUpdateQueue: IPersistentQueue<IAssetUpdateRecord>;

    //
    // The interface to the backend.
    //
    api: IApi;
}

//
// Send outgoing asset uploads and updates to the cloud.
//
export async function syncOutgoing({ outgoingAssetUploadQueue, outgoingAssetUpdateQueue, api }: IProps): Promise<void> {
    //
    // Flush the queue of outgoing asset uploads.
    //
    while (true) {
        const outgoingUpload = await outgoingAssetUploadQueue.getNext();
        if (!outgoingUpload) {
            break;
        }

        await api.uploadSingleAsset(outgoingUpload.setId, outgoingUpload.assetId, outgoingUpload.assetType, outgoingUpload.assetData);
        await outgoingAssetUploadQueue.removeNext();

        console.log(`Processed outgoing upload: ${outgoingUpload.setId}/${outgoingUpload.assetType}/${outgoingUpload.assetId}`);
    }

    //
    // Flush the queue of outgoing asset updates.
    //
    while (true) {
        const outgoingUpdate = await outgoingAssetUpdateQueue.getNext();
        if (!outgoingUpdate) {
            break;
        }

        await api.submitOperations(outgoingUpdate.ops);
        await outgoingAssetUpdateQueue.removeNext();

        console.log(`Processed outgoing updates:`);
        for (const op of outgoingUpdate.ops) {
            console.log(`  ${op.collectionName}/${op.recordId}`);
        }
    }
}    