//
// Specifies the data for an asset.
// 
export interface IAssetData {
    //
    // The ID of the asset.
    //
    _id: string;

    //
    // The content type of the asset.
    //
    contentType: string;

    //
    // The blob containing the data for the asset.
    //
    data: Blob;
}
