import React, { useEffect } from "react";
import { Gallery } from "../../components/gallery";
import { useParams } from "react-router-dom";
import { useGallery } from "../../context/gallery-context";
import { useAssetDatabase } from "../../context/asset-database-source";
import { NoDatabaseLoaded } from "../../components/no-database-loaded";
import { EmptyDatabase } from "../../components/empty-database";
import Box from "@mui/joy/Box";
import CircularProgress from "@mui/joy/CircularProgress";
import { log } from "utils";

export interface IGalleryPageProps {
}

export function GalleryPage({}: IGalleryPageProps) {
    const { setSelectedItemId, allItems, isLoading } = useGallery();
    const { databasePath, loadsFinished } = useAssetDatabase();
    const { assetId } = useParams();

    useEffect(() => {
        if (assetId) {
            // Selects the asset specified in the URL. This reacts only to URL changes, not to
            // selection changes made inside the asset view (prev/next/close), so those are not
            // immediately overridden back to the asset named in the URL.
            setSelectedItemId(assetId);
        }
    }, [assetId, setSelectedItemId]);

    // Said once the gallery is showing a loaded database: on arriving at the page with one open, and
    // each time a load of one finishes. The smoke tests wait on this line.
    //
    // The count of finished loads is watched as well as the loading flag, because the flag alone
    // missed a load on a fast enough device. The iOS simulator on a CI runner finished loading a
    // fifty asset database before React had rendered the load in progress, so the flag's true and
    // false were batched into one render, nothing here changed, and the line for that load was never
    // written: smoke test 53 waited three minutes for it after reopening a database it had just
    // opened successfully on launch, with the gallery's items rendered on screen the whole time.
    useEffect(() => {
        if (databasePath && !isLoading) {
            const count = allItems().length;
            log.info(`Gallery loaded: ${count} assets`);
        }
    // eslint-disable-next-line react-hooks/exhaustive-deps
    }, [isLoading, databasePath, loadsFinished]);

    return (
        <div className="w-full h-full overflow-x-hidden overflow-y-auto relative">
            {!databasePath && (
                <NoDatabaseLoaded />
            )}

            {databasePath && isLoading && allItems().length === 0 && (
                <Box
                    className="flex items-center justify-center"
                    sx={{ height: "calc(100vh - 60px)" }}
                >
                    <CircularProgress variant="soft" />
                </Box>
            )}

            {databasePath && !isLoading && allItems().length === 0 && (
                <EmptyDatabase />
            )}

            {databasePath && allItems().length > 0 && (
                <Gallery />
            )}
        </div>
    );
}
