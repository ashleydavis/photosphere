//
// Interface for uploading and updating assets.
//

import { IAssetData } from "../../def/asset-data";
import { IAssetOp } from "../../def/ops";

export interface IGallerySink {
    //
    // Stores an asset.
    //
    storeAsset(collectionId: string, assetId: string, assetType: string, assetData: IAssetData): Promise<void>;

    //
    // Submits operations to change the database.
    //
    submitOperations(ops: IAssetOp[]): Promise<void>;

    //
    // Check if the asset that has already been uploaded with a particular hash.
    //
    checkAsset(collectionId: string, hash: string): Promise<string | undefined>;
}