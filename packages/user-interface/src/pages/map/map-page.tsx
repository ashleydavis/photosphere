import React, { useEffect } from "react";
import { useNavigate, useParams } from "react-router-dom";
import { useAssetDatabase } from "../../context/asset-database-source";
import { useGallery } from "../../context/gallery-context";
import { GalleryItemContextProvider } from "../../context/gallery-item-context";
import { AssetView } from "../../components/asset-view";
import { MapView } from "./map-view";
import { NoDatabaseLoaded } from "../../components/no-database-loaded";
import Drawer from "@mui/joy/Drawer/Drawer";

export interface IMapPageProps {
}

//
// The map page of the Photosphere app, showing photos with GPS coordinates on a map.
//
export function MapPage({}: IMapPageProps) {
    const { databasePath } = useAssetDatabase();
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
                <NoDatabaseLoaded />
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
