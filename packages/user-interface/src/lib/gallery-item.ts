//
// Represents an asset that can be displayed in the gallery.
//

export interface IGalleryItem {

    //
    // Unique ID of the asset in the database.
    //
    _id: string;

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

    //
    // The computed width of the thumbnail.
    //
    thumbWidth?: number;

    //
    // The computed height of the thumbnail.
    //
    thumbHeight?: number;

    //
    // The aspect ratio of them item, once computed.
    //
    aspectRatio?: number;

    //
    // The group that this item is a part of, if any.
    //
    group?: string;
}

//
// Represents a row in the gallery.
//
export interface IGalleryRow {

    //
    // Items to display in this row in the gallery.
    //
    items: IGalleryItem[];

    //
    // The width of this row in the gallery.
    //
    width: number;

    //
    // The height of this row in the gallery.
    //
    height: number;

    //
    // The group displayed in this row of items, if any.
    //
    group?: string;
}

//
// Represents an item in the gallery that has been selected.
//
export interface ISelectedGalleryItem {
    //
    // The selected item.
    //
    item: IGalleryItem;

    //
    // The index of the selected item in the gallery.
    //
    index: number;
}