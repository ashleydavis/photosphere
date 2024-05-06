//
// Provides a sink for adding/updating assets to indexeddb.
//

import React, { createContext, ReactNode, useContext, useEffect, useRef } from "react";
import { IGalleryItem } from "../../lib/gallery-item";
import { IGallerySink } from "./gallery-sink";
import { getRecord, storeAsset, storeRecord } from "../../lib/indexeddb";
import { IAsset } from "../../def/asset";
import { useIndexeddb } from "../indexeddb-context";
import { ICollectionOps } from "../../def/ops";

//
// Use the "Indexeddb sink" in a component.
//
export function useIndexeddbGallerySink(): IGallerySink {

    const { db } = useIndexeddb();

    //
    // Uploads an asset.
    //
    async function uploadAsset(collectionId: string, assetId: string, assetType: string, contentType: string, assetData: Blob): Promise<void> {
        if (db === undefined) {
            throw new Error("Database not open");
        }

        await storeAsset(db, assetType, assetId, { //todo: Make use of collection id.
            contentType,
            data: assetData,        
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
    // Updates the configuration of the asset.
    //
    async function updateAsset(collectionOps: ICollectionOps): Promise<void> {
        if (db === undefined) {
            throw new Error("Database not open");
        }

        for (const assetOps of collectionOps.ops) {
            const assetId = assetOps.id;
            const asset = await getRecord<IAsset>(db, "metadata", assetId);
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

            await storeRecord<IAsset>(db, "metadata", fields);
        }        
    }

    //
    // Check that asset that has already been uploaded with a particular hash.
    //
    async function checkAsset(collectionId: string, hash: string): Promise<string | undefined> {
        if (db === undefined) {
            throw new Error("Database not open");
        }

        const hashRecord = await getRecord<IHashRecord>(db, "hashes", hash);
        if (!hashRecord) {
            return undefined;
        }

        if (hashRecord.assetIds.length < 1) { 
            return undefined;
        }

        return hashRecord.assetIds[0]; //TODO: This make this cope with hash collisions.
    }

    return {
        uploadAsset,
        updateAsset,
        checkAsset,
    };
}
