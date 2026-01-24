import React, { useEffect } from "react";
import { Gallery } from "../../components/gallery";
import { useParams } from "react-router-dom";
import { useGallery } from "../../context/gallery-context";
import { useAssetDatabase } from "../../context/asset-database-source";
import Button from "@mui/joy/Button";
import Typography from "@mui/joy/Typography";
import Box from "@mui/joy/Box";
import FolderOpenIcon from "@mui/icons-material/FolderOpen";

export interface IGalleryPageProps {
}

export function GalleryPage({}: IGalleryPageProps) {
    const { selectedItemId, setSelectedItemId } = useGallery();
    const { databasePath, selectAndOpenDatabase } = useAssetDatabase();
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
                <Box
                    className="flex items-center justify-center"
                    sx={{
                        height: "calc(100vh - 60px)",
                    }}
                >
                    <Box sx={{ textAlign: 'center' }}>
                        <Typography level="h4" sx={{ mb: 2 }}>
                            No database loaded
                        </Typography>
                        <Typography level="body-md" sx={{ mb: 4, maxWidth: 400, mx: 'auto' }}>
                            Open a database to start viewing your photos and videos.
                        </Typography>
                        <Button
                            variant="soft"
                            color="neutral"
                            size="lg"
                            startDecorator={<FolderOpenIcon />}
                            onClick={async () => {
                                await selectAndOpenDatabase();
                            }}
                            sx={{
                                borderRadius: 's',
                                px: 4,
                            }}
                        >
                            Open a database
                        </Button>
                    </Box>
                </Box>
            )}

            {databasePath && (
                <Gallery />
            )}
        </div>
    );
}
