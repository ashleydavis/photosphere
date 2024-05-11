//
// Provides a sink for adding/updating assets to indexeddb.
//

import { IGallerySink } from "./gallery-sink";
import { IAsset } from "../../def/asset";
import { useIndexeddb } from "../indexeddb-context";
import { IDatabaseOp, IOpSelection } from "../../def/ops";
import { IAssetData } from "../../def/asset-data";
import { IAssetRecord } from "../../def/asset-record";

//
// Use the "Indexeddb sink" in a component.
//
export function useIndexeddbGallerySink(): IGallerySink {

    const { getRecord, storeRecord } = useIndexeddb();

    //
    // Stores an asset.
    //
    async function storeAsset(collectionId: string, assetId: string, assetType: string, assetData: IAssetData): Promise<void> {
        await storeRecord<IAssetRecord>(`collection-${collectionId}`, assetType, {
            _id: assetId,
            storeDate: new Date(),
            assetData,
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
    async function submitOperations(databaseOps: IDatabaseOp[]): Promise<void> {

        for (const databaseOp of databaseOps) {
            const recordId = databaseOp.recordId;
            const asset = await getRecord<IAsset>(`collection-${databaseOp.collectionId}`, databaseOp.collectionName, recordId);
            let fields = asset as any || {};
            if (!asset) {
                // Set the record id when upserting.
                fields._id = recordId;
            }

            applyOperation(databaseOp.op, fields);

            await storeRecord<IAsset>(`collection-${databaseOp.collectionId}`, databaseOp.collectionName, fields);
        }        
    }

    //
    // Apply an operation to a set of fields.
    //
    function applyOperation(op: IOpSelection, fields: any): void {
        switch (op.type) { //todo: This code could definitely be shared with the asset-database in the backend.
            case "set": {
                for (const [name, value] of Object.entries(op.fields)) {
                    fields[name] = value;
                }
                break;
            }

            case "push": {
                if (!fields[op.field]) {
                    fields[op.field] = [];
                }
                fields[op.field].push(op.value);
                break;
            }

            case "pull": {
                if (!fields[op.field]) {
                    fields[op.field] = [];
                }
                fields[op.field] = fields[op.field].filter((v: any) => v !== op.value);
                break;
            }

            default: {
                throw new Error(`Invalid operation type: ${(op as any).type}`);
            }
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
