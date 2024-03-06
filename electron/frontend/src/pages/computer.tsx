//
// This pages displays assets that have been found on the local computer.
//

import React, { useEffect, useState } from "react";
import { useScan } from "../context/scan-context";
import { AssetView, Gallery, GalleryItemContextProvider } from "user-interface";
import { ISelectedGalleryItem } from "user-interface/build/lib/gallery-item";

export function ComputerPage() {

    //
    // The interface for scanning local files.
    //
    const { assets, scanImages } = useScan();

    //
    // Opens the asset view modal.
    //
    const [openAssetView, setOpenAssetView] = useState<boolean>(false);

    //
    // The item in the gallery that is currently selected.
    //
    const [selectedItem, setSelectedItem] = useState<ISelectedGalleryItem | undefined>(undefined);

    //
    // Gets the previous asset, or undefined if none.
    //
    function getPrev(selectedItem: ISelectedGalleryItem): ISelectedGalleryItem | undefined {
        if (selectedItem.index < 0) {
            return undefined;
        }

        if (selectedItem.index > 0) {
            const prevIndex = selectedItem.index-1;
            return {
                item: assets[prevIndex],
                index: prevIndex,
            };
        }
        else {
            return undefined;
        }
    }

    //
    // Gets the next asset, or undefined if none.
    //
    function getNext(selectedItem: ISelectedGalleryItem): ISelectedGalleryItem | undefined {
        
        if (selectedItem.index < 0) {
            return undefined;
        }

        if (selectedItem.index < assets.length-1) {
            const nextIndex = selectedItem.index + 1;
            return {
                item: assets[nextIndex],
                index: nextIndex,
            };
        }
        else {
            return undefined;
        }
    }

    useEffect(() => {
        scanImages();
    }, []);
        
    return (
        <div className="w-full h-full overflow-x-hidden overflow-y-auto relative">
            <Gallery
                items={assets}
                onItemClick={item => {
                    setOpenAssetView(true);
                    setSelectedItem(item);
                }}
                targetRowHeight={150}
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
