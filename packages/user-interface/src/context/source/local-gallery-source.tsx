//
// Provides a source of assets for the gallery from indexeddb.
//

import { IAssetData, IAssetSink, IAssetSource } from "database";
import { useOnline } from "../../lib/use-online";

//
// Use the "Local source" in a component.
//
export function useLocalGallerySource({ indexeddbSource, indexeddbSink, cloudSource }: { indexeddbSource: IAssetSource, indexeddbSink: IAssetSink, cloudSource: IAssetSource }): IAssetSource {

    const { isOnline } = useOnline();

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
        loadAsset,
    };
}
