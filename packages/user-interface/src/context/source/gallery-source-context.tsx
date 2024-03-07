//
// Interface for the a "source" of assets.
//

import { IGalleryItem } from "../../lib/gallery-item";

export interface IGallerySourceContext {
    //
    // The assets currently loaded.
    //
    assets: IGalleryItem[];

    //
    // Updates the configuration of an asset.
    //
    updateAsset(assetIndex: number, assetUpdate: Partial<IGalleryItem>): void;
}