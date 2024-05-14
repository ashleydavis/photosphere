//
// Provides a source of assets for the gallery from indexeddb.
//

import { IGallerySource } from "./gallery-source";
import { useApi } from "../api-context";
import { useIndexeddb } from "../indexeddb-context";
import { IUser } from "../../def/user";
import { IAssetData } from "../../def/asset-data";
import { IAsset } from "../../def/asset";
import { IAssetRecord } from "../../def/asset-record";

//
// Use the "Indexeddb source" in a component.
//
export function useIndexeddbGallerySource(): IGallerySource {

    const api = useApi();
    const indexeddb = useIndexeddb();

    //
    // Loads the user's details.
    //
    async function getUser(): Promise<IUser | undefined> {
        const userId = localStorage.getItem("userId");
        if (!userId) {
            return undefined;
        }

        const userDatabase = await indexeddb.database("user");
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
        const assetCollection = await indexeddb.database(`collection-${collectionId}`);
        const result = await assetCollection.collection<IAsset>("metadata").getAll(1000, undefined); //todo: pagination needs to be passed on
        return result.records;
    }

    //
    // Loads data for an asset.
    //
    async function loadAsset(collectionId: string, assetId: string, assetType: string): Promise<IAssetData | undefined> {
        const assetCollection = await indexeddb.database(`collection-${collectionId}`);
        const assetRecord = await assetCollection.collection<IAssetRecord>(assetType).getOne(assetId);
        if (!assetRecord) {
            return undefined;
        }

        return assetRecord.assetData;
    }

    return {
        isInitialised: true, // Indexedb is always considered online.
        getUser,
        getAssets,
        loadAsset,
    };
}
