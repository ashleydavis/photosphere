//
// Interface for uploading and updating assets.
//

import { ICollectionOps } from "../../def/ops";

export interface IGallerySink {
    //
    // Uploads an asset.
    //
    uploadAsset(collectionId: string, assetId: string, assetType: string, contentType: string, data: Blob): Promise<void>;

    //
    // Submits operations to change the database.
    //
    submitOperations(collectionOps: ICollectionOps): Promise<void>;

    //
    // Check if the asset that has already been uploaded with a particular hash.
    //
    checkAsset(collectionId: string, hash: string): Promise<string | undefined>;
}