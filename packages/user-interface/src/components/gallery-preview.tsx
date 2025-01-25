import React from "react";
import { IGalleryItem } from "../lib/gallery-item";

export interface IGalleryPreviewProps {
    //
    // The gallery item to render.
    //
    item: IGalleryItem;

    //
    // X position of the image.
    //
    x: number;

    //
    // Y position of the image.
    //
    y: number;

    //
    // Width of the image.
    //
    width: number;

    //
    // Height of the image.
    //
    height: number;
}

//
// Renders a preview image for the gallery.
//
export function GalleryPreview({ item, x, y, width, height }: IGalleryPreviewProps) {
    return (
        <div
            style={{
                position: "absolute",
                left: `${x}px`,
                top: `${y}px`,
                width: `${width}px`,
                height: `${height}px`,
                overflow: "hidden",
                opacity: "0.7",
                backgroundColor: item.color && `rgb(${item.color[0]}, ${item.color[1]}, ${item.color[2]})` || undefined,
            }}
        >
        </div>
    );
};