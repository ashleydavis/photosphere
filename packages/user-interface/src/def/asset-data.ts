//
// Packages the data for an asset.
// 
export interface IAssetData {
    //
    // The content type of the asset.
    //
    contentType: string;

    //
    // The blob containing the data for the asset.
    //
    data: Blob;
}
