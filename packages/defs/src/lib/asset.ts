//
// Represents an asset that has been uploaded to the backend.
//

//
// Full asset data.
//
export interface IAsset {

    //
    // Unique ID of the asset in the database.
    //
    _id: string;

    //
    // The ID of the set that contains the asset.
    //
    setId: string;

    //
    // The original name of the asset before it was uploaded.
    //
    origFileName: string;

    //
    // The original directory of the asset before it was uploaded.
    //
    origPath: string;

    //
    // Content type of the original asset.
    //
    contentType: string;

    //
    // Width of the image or video.
    //
    width: number;

    //
    // Height of the image or video.
    //
    height: number;

    //
    // Hash of the asset.
    //
    hash: string;

    //
    // Optional reverse geocoded location for the asset.
    //
    location?: string;

    //
    // The date the file was created.
    //
    fileDate: string;

    //
    // The date the photo was taken, if known.
    //
    photoDate?: string;

    //
    // Date by which to sort the asset.
    //
    sortDate: string;

    //
    /// The date the asset was uploaded.
    //
    uploadDate: string;

    //
    // Optional extra properties for the asset, like exif data.
    //
    properties?: any;

    //
    // Labels attached to the asset.
    //
    labels?: string[];

    //
    // Description of the asset, once the user has set it.
    //
    description?: string;
}