//
// Provides a sink for adding/updating assets to indexeddb.
//

import { IGallerySink } from "./gallery-sink";
import { IAsset } from "../../def/asset";
import { useIndexeddb } from "../indexeddb-context";
import { IAssetData } from "../../def/asset-data";
import { IAssetRecord } from "../../def/asset-record";
import { IDatabaseOp, applyOperation } from "database";

//
// Use the "Indexeddb sink" in a component.
//
export function useIndexeddbGallerySink(): IGallerySink { //todo: can this just be merged up?

    const indexedb = useIndexeddb();

    //
    // Stores an asset.
    //
    async function storeAsset(collectionId: string, assetId: string, assetType: string, assetData: IAssetData): Promise<void> {
        const assetCollection = indexedb.database(`collection-${collectionId}`);
        await assetCollection.collection<IAssetRecord>(assetType).setOne(assetId, {
            _id: assetId,
            storeDate: new Date(),
            assetData,
        });
    }

    //
    // Submits operations to change the database.
    //
    async function submitOperations(databaseOps: IDatabaseOp[]): Promise<void> {

        for (const databaseOp of databaseOps) {
            const recordId = databaseOp.recordId;
            const assetCollection = indexedb.database(`collection-${databaseOp.databaseName}`);
            const asset = await assetCollection.collection<IAssetRecord>(databaseOp.collectionName).getOne(recordId);
            let fields = asset as any || {};
            if (!asset) {
                // Set the record id when upserting.
                fields._id = recordId;
            }

            applyOperation(databaseOp.op, fields);

            await assetCollection.collection<IAssetRecord>(databaseOp.collectionName).setOne(recordId, fields);
        }        
    }

    return {
        storeAsset,
        submitOperations,
    };
}
