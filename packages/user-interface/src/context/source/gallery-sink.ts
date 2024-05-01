//
// Interface for uploading and updating assets.
//

import { IGalleryItem } from "../../lib/gallery-item";

export interface IAssetDetails {
    //
    // The name of the file.
    //
    fileName: string;

    //
    // The width of the image or video.
    //
    width: number;

    //
    // The height of the image or video.
    //
    height: number;

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
    labels: string[];
}

export interface IGallerySink {
    //
    // Uploads an asset.
    //
    uploadAsset(assetId: string, type: string, contentType: string, data: Blob): Promise<void>;

    //
    // Adds an asset to the gallery.
    //
    addAsset(assetDetails: IAssetDetails): Promise<string>;

    //
    // Updates the configuration of an asset.
    //
    updateAsset(assetId: string, assetUpdate: Partial<IGalleryItem>): Promise<void>;
}