import { IApi } from "../../context/api-context";
import { IOutgoingUpdate } from "./outgoing-update";
import { IPersistentQueue } from "./persistent-queue";

interface IProps {

    //
    // Queue of outgoing updates.
    //
    outgoingUpdateQueue: IPersistentQueue<IOutgoingUpdate>;

    //
    // The interface to the backend.
    //
    api: IApi;
}

//
// Send outgoing asset uploads and updates to the cloud.
//
export async function syncOutgoing({ outgoingUpdateQueue, api }: IProps): Promise<void> {
    //
    // Flush the queue of outgoing updates.
    //
    while (true) {
        const outgoingUpdate = await outgoingUpdateQueue.getNext();
        if (!outgoingUpdate) {
            break;
        }

        switch (outgoingUpdate.type) {
            case "upload":
                await api.uploadSingleAsset(outgoingUpdate.setId, outgoingUpdate.assetId, outgoingUpdate.assetType, outgoingUpdate.assetData);
                break;
            case "update":
                await api.submitOperations(outgoingUpdate.ops);
                break;
            default: 
                throw new Error(`Unknown outgoing update type: ${outgoingUpdate}`);
        }

        await outgoingUpdateQueue.removeNext();

        console.log(`Processed outgoing update:`, outgoingUpdate);
    }
}    