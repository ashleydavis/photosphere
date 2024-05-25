//
// Provides a source of assets for the gallery from indexeddb.
//

import { IAsset, IAssetData, IAssetSink, IAssetSource, IPage } from "database";
import { useOnline } from "../../lib/use-online";

//
// Use the "Local source" in a component.
//
export function useLocalGallerySource({ indexeddbSource, indexeddbSink, cloudSource }: { indexeddbSource: IAssetSource, indexeddbSink: IAssetSink, cloudSource: IAssetSource }): IAssetSource {

    const { isOnline } = useOnline();

    //
    // Loads metadata for all assets.
    //
    async function loadAssets(collectionId: string, max: number, next?: string): Promise<IPage<IAsset>> {
        return await indexeddbSource.loadAssets(collectionId, max, next);
    }

    //
    // Maps a hash to the assets already uploaded.
    //
    async function mapHashToAssets(collectionId: string, hash: string): Promise<string[]> {
        return await indexeddbSource.mapHashToAssets(collectionId, hash);
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
            await indexeddbSink.storeAsset(collectionId, assetId, assetType, assetData);
        }
        return assetData;
    }

    return {
        isInitialised: indexeddbSource.isInitialised,
        loadAssets,
        mapHashToAssets,
        loadAsset,
    };
}
