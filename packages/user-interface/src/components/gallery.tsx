import React, { useEffect, useRef, useState } from "react";
import { GalleryLayout } from "./gallery-layout";
import useResizeObserver from "@react-hook/resize-observer";
import { useGallery } from "../context/gallery-context";
import { GalleryItemContextProvider } from "../context/gallery-item-context";
import { AssetView } from "./asset-view";
import { GetHeadingsFn } from "../lib/create-layout";

//
// Adds a small gutter on the right hand side of the gallery for some whitespace.
//
const GUTTER = 8;

export interface IGalleryProps { 
    //
    // The target height for rows in the gallery.
    //
	targetRowHeight: number;

    //
    // Gets headings from a gallery item.
    //
    getHeadings?: GetHeadingsFn;
}

//
// A photo gallery component.
//
export function Gallery({ targetRowHeight, getHeadings }: IGalleryProps) {

    //
    // The interface to the gallery.
    //
    const { 
        selectedItemId, 
        setSelectedItemId,
        getNext, 
        getPrev, 
        getItemById,
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

    useEffect(() => {
        if (selectedItemId && !openAssetView) {
            setOpenAssetView(true);
        }
    }, [selectedItemId])

    return (
        <div 
        	className="pl-1" 
        	ref={containerRef}
            style={{
                height: "100%",
            }}
        	>
        	<GalleryLayout
                galleryWidth={galleryWidth}
                targetRowHeight={targetRowHeight}
                onItemClick={item => { 
                    setOpenAssetView(true)
                    setSelectedItemId(item._id);
                }}        
                getHeadings={getHeadings}        
                />

            {selectedItemId &&
                <GalleryItemContextProvider 
                    assetId={selectedItemId}
                    key={selectedItemId}
                    >
                    <AssetView
                        key={selectedItemId}
                        open={openAssetView}
                        onClose={() => {
                            setOpenAssetView(false);
                            setSelectedItemId(undefined);
                        }}
                        onPrev={() => {
                            setSelectedItemId(getPrev(getItemById(selectedItemId!)!)?._id);
                        }}
                        onNext={() => {
                            setSelectedItemId(getNext(getItemById(selectedItemId!)!)?._id);
                        }}
                        />
                </GalleryItemContextProvider>
            }                
        </div>
    );
}