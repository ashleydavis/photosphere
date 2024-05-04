//
// Interface for uploading and updating assets.
//

import { IAsset } from "../../def/asset";

export interface IGallerySink {
    //
    // Uploads an asset.
    //
    uploadAsset(assetId: string, assetType: string, contentType: string, data: Blob): Promise<void>;

    //
    // Updates the configuration of an asset.
    //
    updateAsset(assetId: string, assetUpdate: Partial<IAsset>): Promise<void>;

    //
    // Check that asset that has already been uploaded with a particular hash.
    //
    checkAsset(hash: string): Promise<string | undefined>;
}