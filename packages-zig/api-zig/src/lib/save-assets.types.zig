//
// Identifies a single asset to be saved to disk.
//
pub const ISaveAssetItem = struct {
    //
    // The ID of the asset.
    //
    assetId: []const u8,

    //
    // The asset type to fetch (e.g. "asset", "display", "thumb").
    //
    assetType: []const u8,

    //
    // The filename to save as.
    //
    filename: []const u8,
};
