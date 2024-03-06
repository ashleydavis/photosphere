import React, { useEffect, useState } from "react";
import { Gallery } from "../../components/gallery";
import InfiniteScroll from "react-infinite-scroller";
import { useGallery } from "../../context/gallery-context";
import { AssetView } from "./components/asset-view";
import { GalleryItemContextProvider } from "../../context/gallery-item-context";

const INFINITE_SCROLL_THRESHOLD = 200;

export interface IGalleryPageProps {
}

export function GalleryPage({}: IGalleryPageProps) {

    //
    // The interface to the gallery.
    //
    const { 
        assets, 
        loadPage, 
        haveMoreAssets,
        selectedItem, 
        setSelectedItem,
        getNext, 
        getPrev, 
    } = useGallery();

    //
    // Opens the asset view modal.
    //
    const [openAssetView, setOpenAssetView] = useState<boolean>(false);

    useEffect(() => {
        // 
        // Loads the first page of the gallery on mount.
        //
        loadPage(1)
            .catch(err => {
                console.error(`Failed to load gallery:`);
                console.error(err);
            });
    }, []);

    return (
        <>
            <div 
                id="gallery" 
                >
                <InfiniteScroll
                    pageStart={1}
                    initialLoad={false}
                    loadMore={loadPage}
                    hasMore={haveMoreAssets}
                    threshold={INFINITE_SCROLL_THRESHOLD}
                    useWindow={false}
                    getScrollParent={() => document.getElementById("gallery")}
                    >
                    <Gallery 
                        items={assets}
                        onItemClick={item => {
                            setOpenAssetView(true);
                            setSelectedItem(item);
                        }}
                        targetRowHeight={150}
                        />
                </InfiniteScroll>
            </div>

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
        </>
    );
}