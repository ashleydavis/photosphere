import React, { useEffect, useRef, useState } from "react";
import { GalleryLayout } from "./gallery-layout";
import useResizeObserver from "@react-hook/resize-observer";
import { useGallery } from "../context/gallery-context";
import { GalleryItemContextProvider } from "../context/gallery-item-context";
import { AssetView } from "./asset-view";
import Drawer from "@mui/material/Drawer";
import { useGalleryLayout } from "../context/gallery-layout-context";
import { log } from "utils";

//
// Reads the style token `tokenName`, which must be a length in pixels such as "32px", as it
// resolves on `element`, so the gallery's layout maths can use the sizes the style guide sets.
// Returns 0 and logs an error when the token is missing or not in pixels.
//
export function readPixelToken(element: HTMLElement, tokenName: string): number {
    const value = getComputedStyle(element).getPropertyValue(tokenName).trim();
    const pixels = parseFloat(value);
    if (!value.endsWith("px") || Number.isNaN(pixels)) {
        log.error(`Style token ${tokenName} is "${value}", not a length in pixels.`);
        return 0;
    }
    return pixels;
}

//
// A photo gallery component.
//
export function Gallery() {

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

    const {
        setGalleryWidth,
        setGalleryGap,
    } = useGalleryLayout();

    //
    // Opens the asset view modal.
    //
    const [openAssetView, setOpenAssetView] = useState<boolean>(false);

    //
    // Reference to the gallery container element.
    //
    const containerRef = useRef<HTMLDivElement>(null);

    //
    // Updates the gallery width when the container is resized, leaving room for the fast-scroll
    // handle at the right edge, and the gap between photos from the --gallery-gap token. The cast
    // is there because version 1 of @react-hook/resize-observer types its target as React 18's
    // RefObject, which React 19's nullable RefObject does not match. The hook already copes with a
    // null current.
    //
    useResizeObserver(containerRef as React.RefObject<HTMLDivElement>, () => {
        const container = containerRef.current!;
        setGalleryGap(readPixelToken(container, "--gallery-gap"));
        setGalleryWidth(container.clientWidth - readPixelToken(container, "--scrubber-thumb-width") - 2);
    });

    useEffect(() => {
        if (selectedItemId && !openAssetView) {
            setOpenAssetView(true);
        }
    }, [selectedItemId]);

    //
    // Closes the full screen asset view.
    //
    function closeAssetView() {
        setOpenAssetView(false);
        setSelectedItemId(undefined);
    }

    return (
        <div 
        	ref={containerRef}
            style={{
                position: "relative",
                height: "100%",
            }}
        	>
        	<GalleryLayout
                onItemClick={item => {
                    setOpenAssetView(true)
                    setSelectedItemId(item._id);
                }}
                />

            {selectedItemId &&
                <GalleryItemContextProvider 
                    assetId={selectedItemId}
                    >
                    <Drawer
                        className="asset-view-drawer"
                        open={openAssetView}
                        onClose={closeAssetView}
                        anchor="left"
                        slotProps={{
                            paper: {
                                sx: {
                                    top: 0,
                                    right: 0,
                                    bottom: 0,
                                    left: 0,
                                    width: "auto",
                                },
                            },
                        }}
                        >
                        <AssetView
                            onClose={closeAssetView}
                            onPrev={() => {
                                setSelectedItemId(getPrev(getItemById(selectedItemId!)!)?._id);
                            }}
                            onNext={() => {
                                setSelectedItemId(getNext(getItemById(selectedItemId!)!)?._id);
                            }}
                        />
                    </Drawer>
                </GalleryItemContextProvider>
            }                
        </div>
    );
}