//
// Provides a sink for adding/updating assets to indexeddb.
//

import { IGallerySink } from "./gallery-sink";
import { IAsset } from "../../def/asset";
import { useIndexeddb } from "../indexeddb-context";
import { ICollectionOps } from "../../def/ops";
import { IAssetData } from "../../def/asset-data";

//
// Use the "Indexeddb sink" in a component.
//
export function useIndexeddbGallerySink(): IGallerySink {

    const { getRecord, storeRecord } = useIndexeddb();

    //
    // Stores an asset.
    //
    async function storeAsset(collectionId: string, assetType: string, assetData: IAssetData): Promise<void> {
        await storeRecord<IAssetData>(`collection-${collectionId}`, assetType, {
            _id: assetData._id,
            contentType: assetData.contentType,
            data: assetData.data,        
        });
    }

    //
    // Maps hashes to assets.
    //
    interface IHashRecord {
        //
        // ID of the record.
        //
        _id: string;

        //
        // Asset ids that map to this hash.
        //
        assetIds: string[];
    }

    //
    // Submits operations to change the database.
    //
    async function submitOperations(collectionOps: ICollectionOps): Promise<void> {
        for (const assetOps of collectionOps.ops) {
            const assetId = assetOps.id;
            const asset = await getRecord<IAsset>(`collection-${collectionOps.id}`, "metadata", assetId);
            let fields = asset as any || {};
            if (!asset) {
                // Set the asset id when upserting.
                fields._id = assetId;
            }

            for (const assetOp of assetOps.ops) {
                switch (assetOp.type) { //todo: This code could definitely be shared with the asset-database in the backend.
                    case "set": {
                        for (const [name, value] of Object.entries(assetOp.fields)) {
                            fields[name] = value;
                        }
                        break;
                    }

                    case "push": {
                        if (!fields[assetOp.field]) {
                            fields[assetOp.field] = [];
                        }
                        fields[assetOp.field].push(assetOp.value);
                        break;
                    }

                    case "pull": {
                        if (!fields[assetOp.field]) {
                            fields[assetOp.field] = [];
                        }
                        fields[assetOp.field] = fields[assetOp.field].filter((v: any) => v !== assetOp.value);
                        break;
                    }

                    default: {
                        throw new Error(`Invalid operation type: ${(assetOp as any).type}`);
                    }
                }
            }

            await storeRecord<IAsset>(`collection-${collectionOps.id}`, "metadata", fields);
        }        
    }

    //
    // Check that asset that has already been uploaded with a particular hash.
    //
    async function checkAsset(collectionId: string, hash: string): Promise<string | undefined> {
        const hashRecord = await getRecord<IHashRecord>(`collection-${collectionId}`, "hashes", hash);
        if (!hashRecord) {
            return undefined;
        }

        if (hashRecord.assetIds.length < 1) { 
            return undefined;
        }

        return hashRecord.assetIds[0]; //TODO: This make this cope with hash collisions.
    }

    return {
        storeAsset,
        submitOperations,
        checkAsset,
    };
}
