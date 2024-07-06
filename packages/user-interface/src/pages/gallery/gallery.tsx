import React, { useEffect } from "react";
import { Gallery } from "../../components/gallery";
import { useParams } from "react-router-dom";
import { useApp } from "../../context/app-context";
import { useGallery } from "../../context/gallery-context";

export interface IGalleryPageProps {
}

export function GalleryPage({}: IGalleryPageProps) {
    const { setId: _setId, setSetId } = useApp();
    const {  selectedItem,  setSelectedItem, getItemById, items } = useGallery();
    const { setId, assetId } = useParams();

    useEffect(() => {
        if (setId && setId !== _setId) {
            // Selects the set specified in the URL.
            setSetId(setId);
        }
    }, [setId]);

    useEffect(() => {
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
    }, [assetId, items]);

    return (
        <div className="w-full h-full overflow-x-hidden overflow-y-auto relative">
            <Gallery 
                targetRowHeight={150}
                />
        </div>
    );
}