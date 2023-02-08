import React, { useEffect } from "react";
import { Gallery } from "../components/gallery";
import { IGalleryItem } from "../lib/gallery-item";
import InfiniteScroll from "react-infinite-scroller";
import { useGallery } from "../context/gallery-context";

const INFINITE_SCROLL_THRESHOLD = 200;

export interface IGalleryPageProps {
    //
    // Event raised when an item in the gallery is clicked.
    //
    onItemClick: (item: IGalleryItem) => void,
}

export function GalleryPage({ onItemClick }: IGalleryPageProps) {

    //
    // The interface to the gallery.
    //
    const { assets, loadPage, haveMoreAssets } = useGallery();

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
		            onItemClick={onItemClick}
		            targetRowHeight={150}
		            />
            </InfiniteScroll>
        </div>
    );
}