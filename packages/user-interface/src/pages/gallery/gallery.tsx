import React, { useEffect } from "react";
import { Gallery } from "../../components/gallery";
import { useParams } from "react-router-dom";
import { useGallery } from "../../context/gallery-context";
import { useAssetDatabase } from "../../context/asset-database-source";

export interface IGalleryPageProps {
}

export function GalleryPage({}: IGalleryPageProps) {
    const { databaseId: _databaseId, setDatabaseId } = useAssetDatabase();
    const {  selectedItemId,  setSelectedItemId } = useGallery();
    const { databaseId, assetId } = useParams();

    useEffect(() => {
        if (databaseId && databaseId !== _databaseId) {
            // Selects the set specified in the URL.
            setDatabaseId(databaseId);
        }

        if (assetId && assetId !== selectedItemId) {
            // Selects the asset specified in the URL.
            setSelectedItemId(assetId);
        }
    }, [databaseId, assetId]);

    return (
        <div className="w-full h-full overflow-x-hidden overflow-y-auto relative">
            <Gallery
                key={databaseId} // Resets the gallery completely when the set changes. Simplest way to reset the scroll of the gallery.
                />
        </div>
    );
}