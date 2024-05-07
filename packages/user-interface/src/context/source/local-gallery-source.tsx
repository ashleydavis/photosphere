//
// Provides a source of assets for the gallery from indexeddb.
//

import { IGallerySource } from "./gallery-source";
import { IGalleryItem } from "../../lib/gallery-item";
import { IUser } from "../../def/user";

//
// Use the "Local source" in a component.
//
export function useLocalGallerySource({ indexeddbSource, cloudSource }: { indexeddbSource: IGallerySource, cloudSource: IGallerySource }): IGallerySource {

    //
    // Loads the user's details.
    //
    async function getUser(): Promise<IUser | undefined> {
        const user = await indexeddbSource.getUser();
        if (user) {
            return user;
        }

        // Fallback to cloud.
        return await cloudSource.getUser();
    }

    //
    // Retreives assets from the source.
    //
    async function getAssets(collectionId: string): Promise<IGalleryItem[]> {
        return await indexeddbSource.getAssets(collectionId);
    }

    //
    // Loads data for an asset.
    //
    async function loadAsset(collectionId: string, assetId: string, assetType: string): Promise<string | undefined> {

        const localAsset = await indexeddbSource.loadAsset(collectionId, assetId, assetType);
        if (localAsset) {
            return localAsset;
        }
        
        // Fallback to cloud.
        return await cloudSource.loadAsset(collectionId, assetId, assetType);        
    }

    //
    // Unloads data for an asset.
    //
    function unloadAsset(collectionId: string, assetId: string, assetType: string): void {
        indexeddbSource.unloadAsset(collectionId, assetId, assetType);
        cloudSource.unloadAsset(collectionId, assetId, assetType);
    }

    return {
        isInitialised: indexeddbSource.isInitialised,
        getUser,
        getAssets,
        loadAsset,
        unloadAsset,
    };
}
