import React, { useEffect } from "react";
import { useNavigate, useParams } from "react-router-dom";
import { useAssetDatabase } from "../../context/asset-database-source";
import { useGallery } from "../../context/gallery-context";
import { GalleryItemContextProvider } from "../../context/gallery-item-context";
import { AssetView } from "../../components/asset-view";
import { MapView } from "./map-view";
import Box from "@mui/joy/Box";
import Typography from "@mui/joy/Typography";
import Button from "@mui/joy/Button";
import Drawer from "@mui/joy/Drawer/Drawer";
import FolderOpenIcon from "@mui/icons-material/FolderOpen";

export interface IMapPageProps {
}

//
// The map page of the Photosphere app, showing photos with GPS coordinates on a map.
//
export function MapPage({}: IMapPageProps) {
    const { databasePath, selectAndOpenDatabase } = useAssetDatabase();
    const { selectedItemId, setSelectedItemId, getPrev, getNext, getItemById } = useGallery();
    const { assetId } = useParams();
    const navigate = useNavigate();

    //
    // Derive openAssetView directly from the URL so there are no competing state effects.
    //
    const openAssetView = !!assetId;

    //
    // Sync selectedItemId from the URL when the assetId param changes.
    //
    useEffect(() => {
        if (assetId) {
            setSelectedItemId(assetId);
        }
    }, [assetId]);

    //
    // Closes the asset view by navigating back to /map, which clears assetId from the URL.
    //
    function closeAssetView(): void {
        setSelectedItemId(undefined);
        navigate('/map');
    }

    return (
        <div className="w-full h-full overflow-hidden relative">
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
                            Open a database to start viewing your photos on the map.
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
                <MapView />
            )}

            {selectedItemId && (
                <GalleryItemContextProvider assetId={selectedItemId}>
                    <Drawer
                        className="asset-view-drawer"
                        open={openAssetView}
                        onClose={closeAssetView}
                        size="lg"
                        anchor="left"
                    >
                        <AssetView
                            onClose={closeAssetView}
                            onPrev={() => {
                                const prev = getPrev(getItemById(selectedItemId!)!);
                                if (prev) {
                                    navigate(`/map/${prev._id}`);
                                }
                            }}
                            onNext={() => {
                                const next = getNext(getItemById(selectedItemId!)!);
                                if (next) {
                                    navigate(`/map/${next._id}`);
                                }
                            }}
                        />
                    </Drawer>
                </GalleryItemContextProvider>
            )}
        </div>
    );
}
