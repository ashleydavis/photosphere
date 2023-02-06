import React, { useEffect, useState } from "react";
import { Gallery } from "../components/gallery";
import { IGalleryItem } from "../lib/gallery-item";
import { useApi } from "../context/api-context";
import InfiniteScroll from "react-infinite-scroller";

const NUM_ASSETS_PER_PAGE = 100;
const INFINITE_SCROLL_THRESHOLD = 200;

export interface IGalleryPageProps {
    //
    // Event raised when an item in the gallery is clicked.
    //
    onItemClick: (item: IGalleryItem) => void,
}

export function GalleryPage({ onItemClick }: IGalleryPageProps) {

    //
    // Interface to the API.
    //
    const api = useApi();

    //
    // Items to display in the gallery.
    //
	const [items, setItems] = useState<IGalleryItem[]>([]);
	
    //
    // Total assets that have been loaded.
    // This is required to determine how many images to load for the next virtual page.
    //
    const [totalLoaded, setTotalLoaded] = useState<number>(0);

    //
    // Set to true when there's more assets to load.
    //
    const [haveMoreAssets, setHaveMoreAssets] = useState<boolean>(true);

    //
    // Loads the requested page number of the gallery.
    //
    async function loadPage(pageNumber: number): Promise<void> {
        
        const skip = totalLoaded;
        const limit = NUM_ASSETS_PER_PAGE;
        
        const assets = await api.getAssets(skip, limit);
        if (assets.length === 0) {
            //
            // Ran out of items to load!
            //
            setHaveMoreAssets(false);
            return;
        }

        //
        // Add newly loaded items to state.
        //
        setItems(items.concat(assets));
        setTotalLoaded(totalLoaded + assets.length);
        setHaveMoreAssets(true);
    }

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
		            items={items}                
		            onItemClick={onItemClick}
		            targetRowHeight={150}
		            />
            </InfiniteScroll>
        </div>
    );
}