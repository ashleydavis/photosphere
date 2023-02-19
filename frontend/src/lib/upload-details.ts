
//
// Details of an asset to be uploaded.
//

import { IResolution } from "./image";

//
// The state of an individual upload.
//
export type UploadState = "already-uploaded" | "pending" | "uploading" | "uploaded";

export interface IUploadDetails {
    //
    // The name of the file.
    //
    fileName: string;
    
    //
    // The original file to upload.
    //
    // This isn't set for assets automatically extracted from zip files because
    // I don't want to hold that data in memory unless I have to.
    //
    file: Blob;

    //
    // The content type of the asset.
    //
    contentType: string;
    
    //
    // The resolution of the asset.
    //
    resolution: IResolution;

    //
    // Full data URL for the thumbnail, so it can be displayed in the browser during the upload.
    //
    thumbnailDataUrl: string;
    
    //
    // Base64 encoded thumbnail for the asset.
    //
    thumbnail: string;
    
    // 
    // The content type of the thumbnail.
    //
    thumbContentType: string;

    //
    // Base64 encoded display asset.
    //
    display: string;

    // 
    // The content type of the display asset.
    //
    displayContentType: string;

    //
    // Hash of the data.
    //
    hash: string;

    //
    // Optional properties, like exif data.
    //
    properties?: any;

    //
    // Reverse geocoded location of the asset, if known.
    //
    location?: string;

    //
    //  Records the status of the upload item.
    //
    status: UploadState;

    //
    // Id assigned to the asset after it is uploaded.
    //
    assetId?: string;

    //
    // The data the file was created.
    //
    fileDate: string;

    //
    // The data the photo was taken if known.
    //
    photoDate?: string;

    //
    // Labels to add to the uploaded asset, if any.
    //
    labels?: string[];
}