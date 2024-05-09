//
// Provides a source of assets for the gallery from indexeddb.
//

import { IGallerySource } from "./gallery-source";
import { IUser } from "../../def/user";
import { IAsset } from "../../def/asset";
import { useOnline } from "../../lib/use-online";
import { useIndexeddb } from "../indexeddb-context";
import { IAssetData } from "../../def/asset-data";
import { IGallerySink } from "./gallery-sink";

//
// Use the "Local source" in a component.
//
export function useLocalGallerySource({ indexeddbSource, indexeddbSink, cloudSource }: { indexeddbSource: IGallerySource, indexeddbSink: IGallerySink, cloudSource: IGallerySource }): IGallerySource {

    const { isOnline } = useOnline();
    const { storeRecord } = useIndexeddb();

    //
    // Loads the user's details.
    //
    async function getUser(): Promise<IUser | undefined> {
        if (isOnline) {
            // Not able to load user details offline.
            const user = await cloudSource.getUser();
            if (user) {
                //
                // Store user locally for offline use.
                //
                await storeRecord("user", "user", user);
                localStorage.setItem("userId", user._id);
                return user;
            }
        }

        // Fallback to indexeddb.
        const user = await indexeddbSource.getUser();
        if (user) {
            return user;
        }
    }

    //
    // Retreives assets from the source.
    //
    async function getAssets(collectionId: string): Promise<IAsset[]> {
        return await indexeddbSource.getAssets(collectionId);
    }

    //
    // Loads data for an asset.
    //
    async function loadAsset(collectionId: string, assetId: string, assetType: string): Promise<IAssetData | undefined> {
        const localAsset = await indexeddbSource.loadAsset(collectionId, assetId, assetType);
        if (localAsset) {
            return localAsset;
        }

        if (!isOnline) {
            return undefined;
        }
        
        // Fallback to cloud.
        const assetData = await cloudSource.loadAsset(collectionId, assetId, assetType);
        if (assetData) {
            // Cache the asset in indexeddb.
            await indexeddbSink.storeAsset(collectionId, assetType, assetData);
        }
        return assetData;
    }

    return {
        isInitialised: indexeddbSource.isInitialised,
        getUser,
        getAssets,
        loadAsset,
    };
}
