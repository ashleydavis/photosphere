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
    const {  selectedItemId,  setSelectedItemId, getItemById, items } = useGallery();
    const { setId, assetId } = useParams();

    useEffect(() => {
        if (setId && setId !== _setId) {
            // Selects the set specified in the URL.
            setSetId(setId);
        }

        if (assetId && assetId !== selectedItemId) {
            // Selects the asset specified in the URL.
            setSelectedItemId(assetId);
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