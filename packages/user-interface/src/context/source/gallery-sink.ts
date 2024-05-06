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
    // Updates the configuration of an asset.
    //
    updateAsset(collectionOps: ICollectionOps): Promise<void>; //todo: this should be renamed because it can accept operations across multiple assets.

    //
    // Check if the asset that has already been uploaded with a particular hash.
    //
    checkAsset(collectionId: string, hash: string): Promise<string | undefined>;
}