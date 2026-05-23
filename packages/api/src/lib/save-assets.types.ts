//
// Identifies a single asset to be saved to disk.
//
export interface ISaveAssetItem {
    //
    // The ID of the asset.
    //
    assetId: string;

    //
    // The asset type to fetch (e.g. "asset", "display", "thumb").
    //
    assetType: string;

    //
    // The filename to save as.
    //
    filename: string;
}
