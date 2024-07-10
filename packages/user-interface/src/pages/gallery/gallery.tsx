import React, { useEffect } from "react";
import { Gallery } from "../../components/gallery";
import { useParams } from "react-router-dom";
import { useApp } from "../../context/app-context";
import { useGallery } from "../../context/gallery-context";
import { useAssetDatabase } from "../../context/asset-database-source";

export interface IGalleryPageProps {
}

export function GalleryPage({}: IGalleryPageProps) {
    const { setId: _setId, setSetId } = useAssetDatabase();
    const {  selectedItem,  setSelectedItem, getItemById, items } = useGallery();
    const { setId, assetId } = useParams();

    useEffect(() => {
        if (items.length === 0) {
            // Items have to be loaded.
            return;
        }

        if (assetId) {
            const newSelectedItem = getItemById(assetId);
            if (selectedItem !== newSelectedItem) {
                // Selects the item specified in the URL.
                setSelectedItem(newSelectedItem);
            }            
        }
        else {
            setSelectedItem(undefined);        
        }

        if (setId && setId !== _setId) {
            // Selects the set specified in the URL.
            setSetId(setId);
        }
    }, [setId, assetId, items]);

    return (
        <div className="w-full h-full overflow-x-hidden overflow-y-auto relative">
            <Gallery 
                key={setId} // Resets the gallery completely when the set changes. Simplest way to reset the scroll of the gallery.
                targetRowHeight={150}
                />
        </div>
    );
}