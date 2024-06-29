
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
    // The path that contains the file, when known.
    //
    filePath?: string;

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
