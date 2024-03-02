import React, { useRef, useState } from "react";
import { IGalleryItem, ISelectedGalleryItem } from "../lib/gallery-item";
import { GalleryLayout } from "./gallery-layout";
import useResizeObserver from "@react-hook/resize-observer";

//
// Adds a small gutter on the right hand side of the gallery for some whitespace.
//
const GUTTER = 8;

export interface IGalleryProps { 
    //
    // The items to display in the gallery.
    //
	items: IGalleryItem[];

    //
    // The target height for rows in the gallery.
    //
	targetRowHeight: number;

    //
    // Event raised when an item in the gallery has been clicked.
    //
    onItemClick: ((item: ISelectedGalleryItem) => void) | undefined;
}

//
// A photo gallery component.
//
export function Gallery({ items, targetRowHeight, onItemClick }: IGalleryProps) {

    //
    // The width of the gallery.
    //
    const [galleryWidth, setGalleryWidth] = useState<number>(0);

    //
    // Reference to the gallery container element.
    //
    const containerRef = useRef<HTMLDivElement>(null);

    //
    // Updates the gallery width when the container is resized.
    //
    useResizeObserver(containerRef, () => {
        setGalleryWidth(containerRef.current!.clientWidth - GUTTER);
    });

    return (
        <div 
        	className="pl-1" 
        	ref={containerRef}
        	>
        	<GalleryLayout
                galleryWidth={galleryWidth}
                targetRowHeight={targetRowHeight}
                items={items}
                onItemClick={onItemClick}
                />
        </div>
    );
}