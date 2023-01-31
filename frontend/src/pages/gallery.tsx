import React, { useEffect, useState } from "react";
import { Gallery } from "../components/gallery";
import { IGalleryItem } from "../components/gallery-item";
import { useApi } from "../context/api-context";

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

	const [items, setItems] = useState<IGalleryItem[]>([]);
	
	useEffect(() => {
        api.getAssets()
            .then(items=> {
                setItems(items);
            })
            .catch(error => {
                console.log(`Error retrieving assets:`);
                console.log(error);
            });
    }, []);

    return (
        <Gallery 
            items={items}                
            onItemClick={onItemClick}
            targetRowHeight={150}
            />
    );
}