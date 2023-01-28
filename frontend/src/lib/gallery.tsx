import React, { useRef, useState } from "react";
import { GalleryLayout } from "./gallery-layout";
import useResizeObserver from "@react-hook/resize-observer";

export interface IGalleryProps { 
    //
    // The items to display in the gallery.
    //
	items: any[];

    //
    // The target height for rows in the gallery.
    //
	targetRowHeight?: number;

    //
    // The URL for the backend.
    //
	baseUrl: string;

    //
    // Event raised when an item in the gallery has been clicked.
    //
    onImageClick: ((item: any) => void) | undefined;
}

//
// A photo gallery component.
//
export function Gallery({ items, targetRowHeight, baseUrl, onImageClick }: IGalleryProps) {

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
        const gutter = 8; // Small gutter to make sure the edge or each rows is not visible.
        setGalleryWidth(containerRef.current!.clientWidth + gutter);
    });

    return (
        <div ref={containerRef}>
        	<GalleryLayout
                galleryWidth={galleryWidth}
                targetRowHeight={targetRowHeight}
                items={items}
                baseUrl={baseUrl}
                onImageClick={onImageClick}
                />
        </div>
    );
}