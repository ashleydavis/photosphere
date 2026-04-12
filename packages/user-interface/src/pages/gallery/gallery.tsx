import React, { useEffect } from "react";
import { Gallery } from "../../components/gallery";
import { useParams } from "react-router-dom";
import { useGallery } from "../../context/gallery-context";
import { useAssetDatabase } from "../../context/asset-database-source";
import { NoDatabaseLoaded } from "../../components/no-database-loaded";
import { EmptyDatabase } from "../../components/empty-database";

export interface IGalleryPageProps {
}

export function GalleryPage({}: IGalleryPageProps) {
    const { selectedItemId, setSelectedItemId, allItems, isLoading } = useGallery();
    const { databasePath } = useAssetDatabase();
    const { assetId } = useParams();

    useEffect(() => {
        if (assetId && assetId !== selectedItemId) {
            // Selects the asset specified in the URL.
            setSelectedItemId(assetId);
        }
    }, [assetId, selectedItemId, setSelectedItemId]);

    return (
        <div className="w-full h-full overflow-x-hidden overflow-y-auto relative">
            {!databasePath && (
                <NoDatabaseLoaded />
            )}

            {databasePath && !isLoading && allItems().length === 0 && (
                <EmptyDatabase />
            )}

            {databasePath && (isLoading || allItems().length > 0) && (
                <Gallery />
            )}
        </div>
    );
}
