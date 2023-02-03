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
    // Partial URL to the asset.
    //
    src: string;

    //
    // Partial URL to the thumbnail for the asset.
    //
    thumb: string;

    //
    // The original name of the asset before it was uploaded.
    //
    origFileName: string;

    //
    // The mime type of the asset.
    //
    contentType: string;

    //
    // The mime type of the thumbnail.
    //
    thumbContentType: string;

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
    // Optional extra properties for the asset, like exif data.
    //
    properties?: any;
}