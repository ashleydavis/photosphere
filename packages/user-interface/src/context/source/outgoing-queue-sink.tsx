//
// Provides a sink that stores outgoing assets in indexeddb and queues them for upload to the cloud.
//

import { IGallerySink } from "./gallery-sink";
import { uuid } from "../../lib/uuid";
import { useIndexeddb } from "../indexeddb-context";
import { IAssetData } from "../../def/asset-data";
import { IDatabaseOp } from "database";

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
    op: IDatabaseOp;
}

//
// Use the outgoing queue sink in a component.
//
export function useOutgoingQueueSink(): IGallerySink {

    const indexeddb = useIndexeddb();

    //
    // Stores an asset.
    //
    async function storeAsset(collectionId: string, assetId: string, assetType: string, assetData: IAssetData): Promise<void> {
        const userDatabase = await indexeddb.database("user");
        const id = uuid();
        await userDatabase.collection("outgoing-asset-upload").setOne(uuid(), {
            _id: uuid(),
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
        const userDatabase = await indexeddb.database("user");
        const updateCollection = await userDatabase.collection("outgoing-asset-update");
        for (const op of ops) {
            const id = uuid();
            await updateCollection.setOne(id, {
                _id: id,
                op,
            });
        }
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
