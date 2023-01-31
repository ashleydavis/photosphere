
//
// Represents an item that can be displayed in the gallery.
//
export interface IGalleryItem {

    //
    // Partial URL of the thumbnail for the item.
    //
    thumb: string;

    //
    // Partial URL for the original full size item.
    //
    src: string;

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