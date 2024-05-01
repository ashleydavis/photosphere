import React, { useRef, useState } from "react";
import { IGalleryItem, ISelectedGalleryItem } from "../lib/gallery-item";
import { GalleryLayout } from "./gallery-layout";
import useResizeObserver from "@react-hook/resize-observer";
import { useGallery } from "../context/gallery-context";
import { GalleryItemContextProvider } from "../context/gallery-item-context";
import { AssetView } from "./asset-view";

//
// Adds a small gutter on the right hand side of the gallery for some whitespace.
//
const GUTTER = 8;

export interface IGalleryProps { 
    //
    // The target height for rows in the gallery.
    //
	targetRowHeight: number;
}

//
// A photo gallery component.
//
export function Gallery({ targetRowHeight }: IGalleryProps) {

    //
    // The interface to the gallery.
    //
    const { 
        selectedItem, 
        setSelectedItem,
        getNext, 
        getPrev, 
    } = useGallery();

    //
    // Opens the asset view modal.
    //
    const [openAssetView, setOpenAssetView] = useState<boolean>(false);

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
                onItemClick={item => { 
                    setOpenAssetView(true);
                    setSelectedItem(item);
                }}                
                />

            {selectedItem &&
                <GalleryItemContextProvider 
                    asset={selectedItem.item}
                    assetIndex={selectedItem.index}
                    key={selectedItem.item._id}
                    >
                    <AssetView
                        key={selectedItem.item._id}
                        open={openAssetView}
                        onClose={() => {
                            setOpenAssetView(false);
                        }}
                        onPrev={() => {
                            setSelectedItem(getPrev(selectedItem));
                        }}
                        onNext={() => {
                            setSelectedItem(getNext(selectedItem));
                        }}
                        />
                </GalleryItemContextProvider>
            }                
        </div>
    );
}