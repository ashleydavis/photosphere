import React, { useEffect, useState } from "react";
import axios from "axios";
import { Gallery } from "../lib/gallery";
import { IGalleryItem } from "../lib/gallery-item";

const BASE_URL = process.env.BASE_URL as string;
if (!BASE_URL) {
    throw new Error(`Set BASE_URL environment variable to the URL for the Photosphere backend.`);
}

console.log(`Expecting backend at ${BASE_URL}.`);

export interface IGalleryPageProps {
    //
    // Event raised when an item in the gallery is clicked.
    //
    onImageClick: (item: IGalleryItem) => void,
}

export function GalleryPage({ onImageClick }: IGalleryPageProps) {

	const [items, setItems] = useState<IGalleryItem[]>([]);
	
	useEffect(() => {
        axios.get(`${BASE_URL}/assets`)
            .then(response => {
                setItems(response.data.assets);
            })
            .catch(error => {
                console.log(`Error retrieving assets:`);
                console.log(error);
            });
    }, []);

    return (
        <Gallery 
            items={items}                
            baseUrl={BASE_URL}
            onImageClick={onImageClick}
            />
    );
}