import React, { useEffect, useRef, useState } from "react";
import Modal from "@mui/joy/Modal/Modal";
import ModalDialog from "@mui/joy/ModalDialog/ModalDialog";
import Button from "@mui/joy/Button/Button";
import Input from "@mui/joy/Input/Input";
import Typography from "@mui/joy/Typography/Typography";
import Stack from "@mui/joy/Stack/Stack";
import { MapContainer, TileLayer, Marker, useMapEvents, useMap } from "react-leaflet";
import L from "leaflet";
import "leaflet/dist/leaflet.css";
import { reverseGeocode } from "../lib/reverse-geocode";
import { useDebounce } from "../lib/use-debounce";

//
// A geographic coordinate.
//
interface ICoordinates {
    //
    // Latitude.
    //
    lat: number;

    //
    // Longitude.
    //
    lng: number;
}

//
// A search result from the Nominatim geocoding API.
//
interface ISearchResult {
    //
    // The display name of the result.
    //
    display_name: string;

    //
    // Latitude string from Nominatim.
    //
    lat: string;

    //
    // Longitude string from Nominatim.
    //
    lon: string;
}

//
// Props for the SetLocationDialog component.
//
export interface ISetLocationDialogProps {
    //
    // Whether the dialog is open.
    //
    open: boolean;

    //
    // The initial coordinates to show on the map.
    //
    initialCoordinates?: ICoordinates;

    //
    // Called when the user confirms a location.
    //
    onSetLocation: (coordinates: ICoordinates, location: string | undefined) => void;

    //
    // Called when the user clears the location.
    //
    onClearLocation: () => void;

    //
    // Called when the dialog is dismissed without saving.
    //
    onClose: () => void;
}

//
// The default map center when no initial coordinates are provided.
//
const DEFAULT_CENTER: ICoordinates = { lat: 20, lng: 0 };

//
// The default zoom level.
//
const DEFAULT_ZOOM = 3;

//
// The zoomed-in zoom level when a pin is placed.
//
const PIN_ZOOM = 13;

//
// Creates a pin marker icon using an inline SVG so it works correctly with Vite bundling.
//
function createPinIcon(): L.DivIcon {
    return L.divIcon({
        html: `
            <svg xmlns="http://www.w3.org/2000/svg" width="28" height="40" viewBox="0 0 28 40">
                <path d="M14 0C6.27 0 0 6.27 0 14c0 9.33 14 26 14 26S28 23.33 28 14C28 6.27 21.73 0 14 0z"
                      fill="#1976d2" stroke="white" stroke-width="1.5"/>
                <circle cx="14" cy="14" r="5" fill="white"/>
            </svg>
        `,
        iconSize: [28, 40],
        iconAnchor: [14, 40],
        className: '',
    });
}

//
// Props for the internal MapClickHandler component.
//
interface IMapClickHandlerProps {
    //
    // Called when the user clicks on the map.
    //
    onMapClick: (coords: ICoordinates) => void;
}

//
// Internal component that listens for map click events to place the pin.
//
function MapClickHandler({ onMapClick }: IMapClickHandlerProps) {
    useMapEvents({
        click(event) {
            onMapClick({ lat: event.latlng.lat, lng: event.latlng.lng });
        },
    });
    return null;
}

//
// Props for the MapFlyTo component.
//
interface IMapFlyToProps {
    //
    // The target coordinates to fly to.
    //
    target: ICoordinates | undefined;

    //
    // The zoom level to fly to.
    //
    zoom: number;
}

//
// Internal component that imperatively flies the map to a target coordinate.
//
function MapFlyTo({ target, zoom }: IMapFlyToProps) {
    const map = useMap();
    const prevTargetRef = useRef<ICoordinates | undefined>(undefined);

    useEffect(() => {
        if (!target) {
            return;
        }

        if (prevTargetRef.current === target) {
            return;
        }

        prevTargetRef.current = target;
        map.flyTo([target.lat, target.lng], zoom, { duration: 0.8 });
    }, [target, zoom, map]);

    return null;
}

//
// Dialog that lets the user set a location by dropping a pin on a map,
// searching for a place, or clearing the existing location.
//
export function SetLocationDialog({ open, initialCoordinates, onSetLocation, onClearLocation, onClose }: ISetLocationDialogProps) {
    //
    // The current pin position, or undefined if no pin is placed.
    //
    const [pinCoords, setPinCoords] = useState<ICoordinates | undefined>(initialCoordinates);

    //
    // The reverse-geocoded location name for the current pin.
    // undefined = not yet geocoded or geocoding in progress, null = geocoding failed.
    //
    const [pinLocation, setPinLocation] = useState<string | null | undefined>(undefined);

    //
    // True while reverse geocoding the dropped pin.
    //
    const [isGeocoding, setIsGeocoding] = useState<boolean>(false);

    //
    // The search query typed by the user.
    //
    const [searchQuery, setSearchQuery] = useState<string>("");

    //
    // True while a forward geocode search is in progress.
    //
    const [isSearching, setIsSearching] = useState<boolean>(false);

    //
    // The target for MapFlyTo to animate to after search or initial load.
    //
    const [flyTarget, setFlyTarget] = useState<ICoordinates | undefined>(undefined);

    //
    // The zoom level to use when flying to a target.
    //
    const [flyZoom, setFlyZoom] = useState<number>(PIN_ZOOM);

    //
    // True while the OK confirmation is being processed.
    //
    const [isConfirming, setIsConfirming] = useState<boolean>(false);

    //
    // Debounce for the search input.
    //
    const searchDebounce = useDebounce(400);

    //
    // Reset state when the dialog opens.
    //
    useEffect(() => {
        if (open) {
            setPinCoords(initialCoordinates);
            setPinLocation(undefined);
            setSearchQuery("");
            setIsSearching(false);
            setIsGeocoding(false);
            setIsConfirming(false);

            if (initialCoordinates) {
                setFlyTarget(initialCoordinates);
                setFlyZoom(PIN_ZOOM);
            }
            else {
                setFlyTarget(undefined);
                setFlyZoom(DEFAULT_ZOOM);
            }
        }
    }, [open]);

    //
    // Reverse geocode whenever the pin position changes.
    //
    useEffect(() => {
        if (!pinCoords) {
            setPinLocation(undefined);
            return;
        }

        setPinLocation(undefined);
        setIsGeocoding(true);

        reverseGeocode(pinCoords.lat, pinCoords.lng)
            .then(location => {
                setPinLocation(location ?? null);
            })
            .finally(() => {
                setIsGeocoding(false);
            });
    }, [pinCoords]);

    //
    // Handles a click on the map to place the pin.
    //
    function onMapClick(coords: ICoordinates): void {
        setPinCoords(coords);
    }

    //
    // Searches for a location by name using Nominatim and flies the map there.
    //
    async function executeSearch(query: string): Promise<void> {
        const trimmed = query.trim();
        if (!trimmed) {
            return;
        }

        setIsSearching(true);
        try {
            const url = `https://nominatim.openstreetmap.org/search?format=json&q=${encodeURIComponent(trimmed)}&limit=1`;
            const response = await fetch(url, { headers: { "Accept-Language": "en" } });
            const results: ISearchResult[] = await response.json();
            if (results.length > 0) {
                const result = results[0];
                const coords: ICoordinates = { lat: parseFloat(result.lat), lng: parseFloat(result.lon) };
                setPinCoords(coords);
                setFlyTarget(coords);
                setFlyZoom(PIN_ZOOM);
            }
        }
        finally {
            setIsSearching(false);
        }
    }

    //
    // Confirms the pin location using the already-geocoded location name.
    //
    async function onConfirm(): Promise<void> {
        if (!pinCoords) {
            return;
        }

        setIsConfirming(true);
        try {
            onSetLocation(pinCoords, pinLocation ?? undefined);
        }
        finally {
            setIsConfirming(false);
        }
    }

    const pinIcon = createPinIcon();

    return (
        <Modal open={open} onClose={onClose}>
            <ModalDialog
                sx={{
                    width: "85vw",
                    height: "85vh",
                    display: "flex",
                    flexDirection: "column",
                    p: 2,
                    gap: 1,
                }}
            >
                <Typography level="title-md">Set Location</Typography>

                <Input
                    placeholder="Search for a place or address..."
                    value={searchQuery}
                    startDecorator={isSearching ? <i className="fa-solid fa-spinner fa-spin" /> : <i className="fa-solid fa-search" />}
                    onChange={event => {
                        const value = event.target.value;
                        setSearchQuery(value);
                        searchDebounce.schedule(() => executeSearch(value));
                    }}
                    onKeyDown={async event => {
                        if (event.key === "Enter") {
                            searchDebounce.cancel();
                            await executeSearch(searchQuery);
                        }
                    }}
                />

                <div style={{ flex: 1, borderRadius: "8px", overflow: "hidden" }}>
                    <MapContainer
                        center={[DEFAULT_CENTER.lat, DEFAULT_CENTER.lng]}
                        zoom={DEFAULT_ZOOM}
                        style={{ width: "100%", height: "100%" }}
                    >
                        <TileLayer
                            attribution='&copy; <a href="https://www.openstreetmap.org/copyright">OpenStreetMap</a> contributors &copy; <a href="https://carto.com/attributions">CARTO</a>'
                            url="https://{s}.basemaps.cartocdn.com/rastertiles/voyager/{z}/{x}/{y}{r}.png"
                        />
                        <MapClickHandler onMapClick={onMapClick} />
                        <MapFlyTo target={flyTarget} zoom={flyZoom} />
                        {pinCoords && (
                            <Marker
                                position={[pinCoords.lat, pinCoords.lng]}
                                icon={pinIcon}
                            />
                        )}
                    </MapContainer>
                </div>

                {pinCoords && (
                    <Stack spacing={0}>
                        <Typography level="body-xs" sx={{ color: "text.secondary" }}>
                            {pinCoords.lat.toFixed(6)}, {pinCoords.lng.toFixed(6)}
                        </Typography>
                        <Typography level="body-sm">
                            {isGeocoding
                                ? "Looking up location..."
                                : (pinLocation ?? "Location unknown")
                            }
                        </Typography>
                    </Stack>
                )}

                {!pinCoords && (
                    <Typography level="body-xs" sx={{ color: "text.secondary" }}>
                        Click on the map to place a pin.
                    </Typography>
                )}

                <Stack direction="row" spacing={1} justifyContent="space-between">
                    <Button
                        variant="plain"
                        color="danger"
                        onClick={onClearLocation}
                    >
                        Clear location
                    </Button>
                    <Stack direction="row" spacing={1}>
                        <Button variant="outlined" color="neutral" onClick={onClose}>
                            Cancel
                        </Button>
                        <Button
                            variant="solid"
                            color="primary"
                            disabled={!pinCoords}
                            loading={isConfirming}
                            onClick={onConfirm}
                        >
                            OK
                        </Button>
                    </Stack>
                </Stack>
            </ModalDialog>
        </Modal>
    );
}
