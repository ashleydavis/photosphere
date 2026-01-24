import React, { useEffect } from "react";
import { Gallery } from "../../components/gallery";
import { useParams } from "react-router-dom";
import { useGallery } from "../../context/gallery-context";
import { useAssetDatabase } from "../../context/asset-database-source";
import { useTheme } from "@mui/joy";

export interface IGalleryPageProps {
}

export function GalleryPage({}: IGalleryPageProps) {
    const { selectedItemId, setSelectedItemId } = useGallery();
    const { databasePath, selectAndOpenDatabase } = useAssetDatabase();
    const { assetId } = useParams();
    const theme = useTheme();

    useEffect(() => {
        if (assetId && assetId !== selectedItemId) {
            // Selects the asset specified in the URL.
            setSelectedItemId(assetId);
        }
    }, [assetId, selectedItemId, setSelectedItemId]);

    return (
        <div className="w-full h-full overflow-x-hidden overflow-y-auto relative">
            {!databasePath && (
                <div
                    className="flex items-center justify-center"
                    style={{
                        height: "calc(100vh - 60px)",
                    }}
                >
                    <div className="text-center">
                        <button
                            onClick={async () => {
                                await selectAndOpenDatabase();
                            }}
                            className="px-6 py-3 bg-blue-500 text-white rounded-lg hover:bg-blue-600 transition-colors"
                            style={{
                                backgroundColor: theme.palette.primary[500] || "#3b82f6",
                            }}
                        >
                            Open a database
                        </button>
                    </div>
                </div>
            )}

            {databasePath && (
                <Gallery />
            )}
        </div>
    );
}
