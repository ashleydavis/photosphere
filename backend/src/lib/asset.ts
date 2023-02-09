import { ObjectId } from "mongodb";

//
// Represents an asset that has been uploaded to the backend.
//
export interface IAsset {

    //
    // Unique ID of the asset in the database.
    //
    _id: ObjectId;

    //
    // The original name of the asset before it was uploaded.
    //
    origFileName: string;

    //
    // The mime type of the asset.
    //
    contentType: string;

    //
    // The mime type of the thumbnail (after one has been set).
    //
    thumbContentType?: string;

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
    fileDate: Date;

    //
    // The date the photo was taken, if known.
    //
    photoDate?: Date;

    //
    // Date by which to sort the asset.
    //
    sortDate: Date;

    //
    /// The date the asset was uploaded.
    //
    uploadDate: Date;

    //
    // Optional extra properties for the asset, like exif data.
    //
    properties?: any;

    //
    // Labels attached to the asset.
    //
    labels: string[];
}