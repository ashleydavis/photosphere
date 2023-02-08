
//
// Represents an asset that can be displayed in the gallery.
//
export interface IGalleryItem {

    //
    // The ID of the asset.
    //
    _id: string;

    //
    // The width of the item.
    //
    width: number;

    //
    // The height of item.
    //
    height: number;

    //
    // The aspect ratio of them item, once computed.
    //
    aspectRatio?: number;

    //
    // The group that this item is a part of, if any.
    //
    group?: string;

    //
    // The hash of the asset.
    //
    hash: string;

    //
    // Reverse geocoded location of the asset, if known.
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
    /// The date the asset is sorted by in the backend.
    //
    sortDate: string;

    //
    /// The date the asset was uploaded.
    //
    uploadDate: string;

    //
    // Optional properties, like exif data.
    //
    properties?: any;

    //
    // Labels that have been added to the asset.
    //
    labels: string[];
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