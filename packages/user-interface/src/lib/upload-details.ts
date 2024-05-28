
//
// Details of an asset to be uploaded.
//

import { IResolution } from "./image";

//
// The state of an individual upload.
//
export type UploadState = "already-uploaded" | "pending" | "uploading" | "uploaded" | "failed";

export interface IQueuedUpload {
    //
    // The name of the file.
    //
    fileName: string;

    //
    // Loads the file into a blob.
    //
    loadData: () => Promise<Blob>;

    //
    // The content type of the asset.
    //
    assetContentType: string;

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
    // Labels to add to the uploaded asset, if any.
    //
    labels: string[];

    //
    // Small thumbnail to show while uploading.
    //
    previewThumbnail: JSX.Element | undefined;

    //
    // Number of attempts to upload.
    //
    numAttempts: number;
}

//
// Details of an asset to be uploaded.
//
export interface IUploadDetails extends IQueuedUpload {

    //
    // The resolution of the asset.
    //
    resolution: IResolution;

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
    // The data the photo was taken if known.
    //
    photoDate?: string;
}