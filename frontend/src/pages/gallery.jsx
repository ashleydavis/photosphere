import React, { useEffect, useState } from "react";
import axios from "axios";
import { Gallery } from "../lib/gallery";

const BASE_URL = process.env.BASE_URL;
if (!BASE_URL) {
    throw new Error(`Set BASE_URL environment variable to the URL for the Photosphere backend.`);
}

console.log(`Expecting backend at ${BASE_URL}.`);

export function GalleryPage({ onImageClick }) {

    const [items, setItems] = useState([]);

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