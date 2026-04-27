import React, { ReactNode, useEffect, useMemo, useRef, useState } from "react";
import { log } from "utils";
import { IGalleryItem } from "../../lib/gallery-item";
import { GallerySourceContext, IGalleryItemMap, IGallerySource, IItemsUpdate, useGallerySource } from "../../context/gallery-source";
import { GalleryContextProvider } from "../../context/gallery-context";
import { GalleryLayoutContextProvider } from "../../context/gallery-layout-context";
import { Gallery } from "../../components/gallery";
import { Observable } from "../../lib/subscription";
import Modal from "@mui/joy/Modal";
import ModalDialog from "@mui/joy/ModalDialog";
import ModalClose from "@mui/joy/ModalClose";
import Typography from "@mui/joy/Typography";
import Box from "@mui/joy/Box";

export interface IClusterModalProps {
    //
    // The items in this cluster to display.
    //
    items: IGalleryItem[];

    //
    // Latitude of the cluster centroid, used for reverse geocoding the title.
    //
    lat: number;

    //
    // Longitude of the cluster centroid, used for reverse geocoding the title.
    //
    lng: number;

    //
    // Called when the modal is closed.
    //
    onClose: () => void;
}

export interface IStaticGallerySourceProviderProps {
    //
    // The fixed set of gallery items to expose through the source.
    //
    items: IGalleryItem[];

    //
    // Child components that will consume this source.
    //
    children: ReactNode | ReactNode[];
}

//
// Provides a static, read-only gallery source for a fixed set of items.
// Allows the Gallery component to be reused inside a modal for a subset of photos.
//
function StaticGallerySourceProvider({ items, children }: IStaticGallerySourceProviderProps) {
    const outerSource = useGallerySource();

    const onReset = useRef(new Observable<void>());
    const onNewItems = useRef(new Observable<IGalleryItem[]>());
    const onItemsUpdated = useRef(new Observable<IItemsUpdate>());
    const onItemsDeleted = useRef(new Observable<IItemsUpdate>());

    //
    // Map from asset ID to item for O(1) lookup.
    //
    const itemsMap = useMemo<IGalleryItemMap>(() => {
        const map: IGalleryItemMap = {};
        for (const item of items) {
            map[item._id] = item;
        }
        return map;
    }, [items]);

    //
    // Fire onNewItems after mount so GalleryContextProvider (a child) has already
    // subscribed by the time this parent effect runs.
    //
    useEffect(() => {
        onNewItems.current.invoke(items);
    }, [items]);

    const source: IGallerySource = {
        isLoading: false,
        isWorking: false,
        isReadOnly: true,
        getAssets: () => itemsMap,
        onReset: onReset.current,
        onNewItems: onNewItems.current,
        onItemsUpdated: onItemsUpdated.current,
        onItemsDeleted: onItemsDeleted.current,
        updateAsset: async () => {},
        updateAssets: async () => {},
        addArrayValue: (assetId, field, value) => outerSource.addArrayValue(assetId, field, value),
        removeArrayValue: (assetId, field, value) => outerSource.removeArrayValue(assetId, field, value),
        deleteAssets: async () => {},
        loadAsset: (assetId, assetType) => outerSource.loadAsset(assetId, assetType),
        getItemById: (assetId) => itemsMap[assetId],
    };

    return (
        <GallerySourceContext.Provider value={source}>
            {children}
        </GallerySourceContext.Provider>
    );
}

//
// Modal gallery popup showing all photos in a map cluster, using the standard Gallery component.
//
export function ClusterModal({ items, lat, lng, onClose }: IClusterModalProps) {
    //
    // Number of photos in the cluster, shown in the title.
    //
    const photoCount = items.length;

    //
    // The photo count label, e.g. "5 photos" or "1 photo".
    //
    const countLabel = `${photoCount} photo${photoCount !== 1 ? 's' : ''}`;

    //
    // The default location name uses the first item that has a pre-computed location string.
    // Used as a fallback if reverse geocoding fails.
    //
    const defaultLocationName = useMemo<string | undefined>(() => {
        return items.find(item => item.location)?.location;
    }, [items]);

    //
    // Reverse-geocoded place name; undefined while in progress, null if failed.
    //
    const [geocodedName, setGeocodedName] = useState<string | null | undefined>(undefined);

    //
    // Fetch a human-readable location name from Nominatim using the cluster centroid.
    // If the fetch fails (e.g. offline) the title shows the count only.
    //
    useEffect(() => {
        setGeocodedName(undefined);
        const url = `https://nominatim.openstreetmap.org/reverse?format=json&lat=${lat}&lon=${lng}`;
        log.info(`Reverse geocoding: GET ${url}`);
        fetch(url, {
            headers: { "Accept-Language": "en" },
        })
            .then(response => {
                log.info(`Reverse geocoding response: ${response.status} ${response.statusText}`);
                return response.json();
            })
            .then(data => {
                log.info(`Reverse geocoding data: ${JSON.stringify(data)}`);
                const address = data.address;
                const name = address?.city
                    || address?.town
                    || address?.village
                    || address?.county
                    || address?.state
                    || address?.country
                    || data.display_name;
                if (name) {
                    setGeocodedName(name);
                }
            })
            .catch(error => {
                log.exception(`Reverse geocoding failed:`, error as Error);
                setGeocodedName(null);
            });
    }, [lat, lng]);

    //
    // The title shown in the modal header.
    // While geocoding is in progress (undefined), show count only.
    // On success use the geocoded name; on failure fall back to the stored location field.
    //
    const locationName = geocodedName === undefined ? undefined : (geocodedName ?? defaultLocationName);
    const title = locationName ? `${countLabel} at ${locationName}` : countLabel;

    return (
        <Modal open onClose={onClose}>
            <ModalDialog
                sx={{
                    width: '95vw',
                    height: '95vh',
                    maxWidth: '95vw',
                    maxHeight: '95vh',
                    display: 'flex',
                    flexDirection: 'column',
                    overflow: 'hidden',
                    p: 2,
                }}
            >
                <ModalClose />
                <Typography level="title-md" sx={{ mb: 1, pr: 4, overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>
                    {title}
                </Typography>
                <Box
                    className="cluster-modal-gallery"
                    sx={{ flex: 1, minHeight: 0, overflow: 'hidden', position: 'relative', transform: 'translateZ(0)' }}
                >
                    <StaticGallerySourceProvider items={items}>
                        <GalleryContextProvider>
                            <GalleryLayoutContextProvider>
                                <Gallery />
                            </GalleryLayoutContextProvider>
                        </GalleryContextProvider>
                    </StaticGallerySourceProvider>
                </Box>
            </ModalDialog>
        </Modal>
    );
}
