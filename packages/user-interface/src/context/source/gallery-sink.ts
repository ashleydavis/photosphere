//
// Interface for uploading and updating assets.
//

import { IDatabaseOp } from "database";
import { IAssetData } from "../../def/asset-data";

export interface IGallerySink {
    //
    // Stores an asset.
    //
    storeAsset(collectionId: string, assetId: string, assetType: string, assetData: IAssetData): Promise<void>;

    //
    // Submits operations to change the database.
    //
    submitOperations(ops: IDatabaseOp[]): Promise<void>;
}