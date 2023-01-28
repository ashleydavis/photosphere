import React, { useRef, useState } from "react";
import { GalleryLayout } from "./gallery-layout";
import useResizeObserver from "@react-hook/resize-observer";

//
// A photo gallery component.
//
export function Gallery({ items, targetRowHeight, baseUrl }) {

    //
    // The width of the gallery.
    //
    const [galleryWidth, setGalleryWidth] = useState(0);

    //
    // Reference to the gallery container element.
    //
    const containerRef = useRef(null);

    //
    // Updates the gallery width when the container is resized.
    //
    useResizeObserver(containerRef, () => {
        const gutter = 8; // Small gutter to make sure the edge or each rows is not visible.
        setGalleryWidth(containerRef.current.clientWidth + gutter);
    });

    return (
        <div ref={containerRef}>
        	<GalleryLayout
                galleryWidth={galleryWidth}
                targetRowHeight={targetRowHeight}
                items={items}
                baseUrl={baseUrl}
                />
        </div>
    );
}