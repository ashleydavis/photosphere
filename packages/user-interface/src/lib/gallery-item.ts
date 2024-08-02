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
    origPath?: string;

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
    /// The date the asset was uploaded.
    //
    uploadDate: string;

    //
    // Optional extra properties for the asset, like exif data.
    //
    properties?: any;

    //
    // Labels that have been added to the asset.
    //
    labels?: string[];

    //
    // Description of the asset, once it has been set by the user.
    //
    description?: string;

    //
    // The horizontal location where the image starts in the gallery.
    //
    offsetX?: number;

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
    // Marks the asset as deleted if set to true.
    //
    deleted?: boolean;

    //
    // The user that uploaded the asset.
    //
    userId: string;
}

//
// Represents a row in the gallery.
//
export interface IGalleryRow {

    //
    // The type of this row.
    //
    type?: "heading";
    
    //
    // Items to display in this row in the gallery.
    //
    items: IGalleryItem[];

    //
    // The vertical location where the row starts in the gallery.
    //
    offsetY: number;

    //
    // The width of this row in the gallery.
    //
    width: number;

    //
    // The height of this row in the gallery.
    //
    height: number;

    //
    // The headings displayed for this row of items.
    //
    headings: string[];
}
