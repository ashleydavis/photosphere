//
// Represents an asset that can be displayed in the gallery.
//

import { IAsset } from "defs";

export interface IGalleryItem extends Omit<IAsset, "setId"> {

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