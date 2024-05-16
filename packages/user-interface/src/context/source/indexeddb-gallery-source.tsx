//
// Provides a source of assets for the gallery from indexeddb.
//

import { IGallerySource } from "./gallery-source";
import { useIndexeddb } from "../indexeddb-context";
import { IUser } from "../../def/user";
import { IAssetData } from "../../def/asset-data";
import { IAsset } from "../../def/asset";
import { IAssetRecord } from "../../def/asset-record";
import { IHashRecord } from "../../def/hash-record";

//
// Use the "Indexeddb source" in a component.
//
export function useIndexeddbGallerySource(): IGallerySource {

    const indexeddb = useIndexeddb();

    //
    // Loads the user's details.
    //
    async function getUser(): Promise<IUser | undefined> {
        const userId = localStorage.getItem("userId");
        if (!userId) {
            return undefined;
        }

        const userDatabase = indexeddb.database("user");
        const user = await userDatabase.collection<IUser>("user").getOne(userId);
        if (!user) {
            return undefined;
        }

        return user;
    }

    //
    // Retreives assets from the source.
    //
    async function getAssets(collectionId: string): Promise<IAsset[]> {
        const assetCollection = indexeddb.database(`collection-${collectionId}`);
        const result = await assetCollection.collection<IAsset>("metadata").getAll(1000, undefined); //todo: pagination needs to be passed on
        return result.records;
    }

    //
    // Loads data for an asset.
    //
    async function loadAsset(collectionId: string, assetId: string, assetType: string): Promise<IAssetData | undefined> {
        const assetCollection = indexeddb.database(`collection-${collectionId}`);
        const assetRecord = await assetCollection.collection<IAssetRecord>(assetType).getOne(assetId);
        if (!assetRecord) {
            return undefined;
        }

        return assetRecord.assetData;
    }

    //
    // Gets the assets already uploaded with a particular hash.
    //
    async function checkAssets(collectionId: string, hash: string): Promise<string[] | undefined> {
        const assetCollection = indexeddb.database(`collection-${collectionId}`);
        const hashRecord = await assetCollection.collection<IHashRecord>("hashes").getOne(hash);
        if (!hashRecord) {
            return undefined;
        }

        if (hashRecord.assetIds.length < 1) { 
            return undefined;
        }

        return hashRecord.assetIds;
    }


    return {
        isInitialised: true, // Indexedb is always considered online.
        getUser,
        getAssets,
        loadAsset,
        checkAssets,
    };
}
