import { IApi, IAsset, IAssetData, IAssetSource, IHashRecord, IPage } from "database";

//
// Provides a source of assets for the gallery from the cloud.
//
export function useCloudGallerySource({ api }: { api: IApi }): IAssetSource {

    //
    // Loads metadata for all assets.
    //
    async function loadAssets(collectionId: string, max: number, next?: string): Promise<IPage<IAsset>> {
        return await api.getAll(collectionId, "metadata", max, next);
    }

    //
    // Maps a hash to the assets already uploaded.
    //
    async function mapHashToAssets(collectionId: string, hash: string): Promise<string[]> {
        const hashRecord = await api.getOne<IHashRecord>(collectionId, "hashes", hash);
        if (!hashRecord) {
            return [];
        }

        return hashRecord.assetIds;
    }

    //
    // Loads data for an asset.
    //
    async function loadAsset(collectionId: string, assetId: string, assetType: string): Promise<IAssetData | undefined> {
        const assetBlob = await api.getAsset(collectionId, assetId, assetType);
        return {
            contentType: assetBlob.type,
            data: assetBlob,
        };
    }

    return {
        isInitialised: api.isInitialised,
        loadAssets,
        mapHashToAssets,
        loadAsset,
    };
}
