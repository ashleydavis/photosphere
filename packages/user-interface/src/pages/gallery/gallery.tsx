import React, { useEffect } from "react";
import { Gallery } from "../../components/gallery";
import { useParams } from "react-router-dom";
import { useGallery } from "../../context/gallery-context";
import { useAssetDatabase } from "../../context/asset-database-source";

export interface IGalleryPageProps {
}

export function GalleryPage({}: IGalleryPageProps) {
    const { databasePath } = useAssetDatabase();
    const { selectedItemId, setSelectedItemId } = useGallery();
    const { assetId } = useParams();

    useEffect(() => {
        if (assetId && assetId !== selectedItemId) {
            // Selects the asset specified in the URL.
            setSelectedItemId(assetId);
        }
    }, [assetId, selectedItemId, setSelectedItemId]);

    return (
        <div className="w-full h-full overflow-x-hidden overflow-y-auto relative">
            <Gallery
                key={databasePath} // Resets the gallery completely when the database changes. Simplest way to reset the scroll of the gallery.
                />
        </div>
    );
}