import React, { useEffect, useRef, useState } from "react";
import { GalleryLayout } from "./gallery-layout";
import useResizeObserver from "@react-hook/resize-observer";
import { useGallery } from "../context/gallery-context";
import { GalleryItemContextProvider } from "../context/gallery-item-context";
import { AssetView } from "./asset-view";
import { SCROLLBAR_WIDTH } from "./gallery-scrollbar";
import Drawer from "@mui/joy/Drawer/Drawer";
import { useGalleryLayout } from "../context/gallery-layout-context";

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
    // Updates the gallery width when the container is resized.
    //
    useResizeObserver(containerRef, () => {
        setGalleryWidth(containerRef.current!.clientWidth - SCROLLBAR_WIDTH - 2);
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
        	className="pl-1" 
        	ref={containerRef}
            style={{
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
                        size="lg"
                        anchor="left"
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