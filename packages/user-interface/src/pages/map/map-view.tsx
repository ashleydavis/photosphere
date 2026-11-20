import React, { useEffect, useState } from "react";
import { MapContainer, TileLayer, Marker, useMap, useMapEvents } from "react-leaflet";
import L from "leaflet";
import { useColorScheme } from "@mui/material/styles";
import "leaflet/dist/leaflet.css";
import { useNavigate } from "react-router-dom";
import { IGalleryItem } from "../../lib/gallery-item";
import { useGallery } from "../../context/gallery-context";
import { useAssetDatabase } from "../../context/asset-database-source";
import { ClusterModal } from "./cluster-modal";

//
// Represents a cluster of photos at a geographic location.
//
interface ICluster {
    //
    // The latitude of the cluster centroid.
    //
    lat: number;

    //
    // The longitude of the cluster centroid.
    //
    lng: number;

    //
    // All items in this cluster.
    //
    items: IGalleryItem[];
}

//
// Represents the current map viewport bounds.
//
interface IMapBounds {
    //
    // Northern latitude boundary.
    //
    northLat: number;

    //
    // Southern latitude boundary.
    //
    southLat: number;

    //
    // Western longitude boundary.
    //
    westLng: number;

    //
    // Eastern longitude boundary.
    //
    eastLng: number;

    //
    // Current zoom level.
    //
    zoom: number;
}

//
// Groups viewport-visible items with GPS coordinates into geographic clusters based on zoom level.
//
function clusterItems(items: IGalleryItem[], zoom: number): ICluster[] {
    const gridSize = 360 / Math.pow(2, zoom + 1);
    const cells = new Map<string, IGalleryItem[]>();

    for (const item of items) {
        if (!item.coordinates) {
            continue;
        }

        const cellLat = Math.floor(item.coordinates.lat / gridSize);
        const cellLng = Math.floor(item.coordinates.lng / gridSize);
        const key = `${cellLat},${cellLng}`;

        if (!cells.has(key)) {
            cells.set(key, []);
        }

        cells.get(key)!.push(item);
    }

    return Array.from(cells.values()).map(cellItems => ({
        lat: cellItems.reduce((sum, item) => sum + item.coordinates!.lat, 0) / cellItems.length,
        lng: cellItems.reduce((sum, item) => sum + item.coordinates!.lng, 0) / cellItems.length,
        items: cellItems,
    }));
}

//
// Returns true if the given coordinates are within the map bounds.
//
function isInBounds(lat: number, lng: number, bounds: IMapBounds): boolean {
    return (
        lat >= bounds.southLat &&
        lat <= bounds.northLat &&
        lng >= bounds.westLng &&
        lng <= bounds.eastLng
    );
}

//
// Creates a Leaflet divIcon for a single-photo marker: the photo's thumbnail in the map marker's
// rounded square, edged in the marker border colour so it stands off the map in either theme.
//
function createSinglePhotoIcon(item: IGalleryItem, thumbUrl: (item: IGalleryItem) => string): L.DivIcon {
    return L.divIcon({
        html: `
            <div style="
                width: 48px;
                height: 48px;
                box-sizing: border-box;
                border-radius: var(--map-marker-radius);
                overflow: hidden;
                border: var(--map-marker-border-width) solid var(--color-map-marker-border);
                box-shadow: var(--shadow-overlay);
                background: var(--color-raised);
                cursor: pointer;
            ">
                <img src="${thumbUrl(item)}" style="display: block; width: 100%; height: 100%; object-fit: cover;" />
            </div>
        `,
        iconSize: [48, 48],
        iconAnchor: [24, 24],
        className: '',
    });
}

//
// Creates a Leaflet divIcon for a cluster marker showing a stack of up to 3 photos.
//
function createClusterIcon(cluster: ICluster, thumbUrl: (item: IGalleryItem) => string): L.DivIcon {
    const stackItems = cluster.items.slice(0, 3);

    //
    // Rotation and offset for each layer of the stack (back to front).
    //
    const layers: { rotation: number; offsetX: number; offsetY: number }[] = [
        { rotation: 10,  offsetX: 10, offsetY: 4 },
        { rotation: -6,  offsetX: 5,  offsetY: 2 },
        { rotation: 0,   offsetX: 0,  offsetY: 0 },
    ];

    const photoSize = 48;
    const containerSize = 72;
    const baseLeft = 8;
    const baseTop = 8;

    const layersHtml = stackItems.map((item, index) => {
        const layer = layers[layers.length - stackItems.length + index];
        return `
            <div style="
                position: absolute;
                left: ${baseLeft + layer.offsetX}px;
                top: ${baseTop + layer.offsetY}px;
                width: ${photoSize}px;
                height: ${photoSize}px;
                box-sizing: border-box;
                border-radius: var(--map-cluster-radius);
                overflow: hidden;
                border: var(--map-marker-border-width) solid var(--color-map-marker-border);
                box-shadow: var(--shadow-overlay);
                background: var(--color-raised);
                transform: rotate(${layer.rotation}deg);
                transform-origin: center;
            ">
                <img src="${thumbUrl(item)}" style="display: block; width: 100%; height: 100%; object-fit: cover;" />
            </div>
        `;
    }).join('');

    return L.divIcon({
        html: `
            <div style="position: relative; width: ${containerSize}px; height: ${containerSize}px; cursor: pointer;">
                ${layersHtml}
                <div style="
                    position: absolute;
                    top: 0;
                    right: 0;
                    display: flex;
                    align-items: center;
                    justify-content: center;
                    box-sizing: border-box;
                    min-width: calc(var(--space-6) - var(--space-1));
                    height: calc(var(--space-6) - var(--space-1));
                    padding: 0 var(--space-1);
                    background: var(--color-badge-bg);
                    color: var(--color-badge-text);
                    border: calc(var(--space-1) / 2) solid var(--color-map-marker-border);
                    border-radius: var(--radius-full);
                    font-size: var(--text-xs);
                    font-weight: var(--weight-bold);
                    font-family: var(--font-sans);
                    line-height: 1;
                ">
                    ${cluster.items.length}
                </div>
            </div>
        `,
        iconSize: [containerSize, containerSize],
        iconAnchor: [containerSize / 2, containerSize / 2],
        className: '',
    });
}

export interface IMapEventsProps {
    //
    // Called when the map viewport changes (zoom or pan).
    //
    onBoundsChange: (bounds: IMapBounds) => void;
}

//
// Internal component that hooks into Leaflet map events to track viewport changes.
//
function MapEvents({ onBoundsChange }: IMapEventsProps) {
    const map = useMap();

    //
    // Reads the current map bounds and reports them to the parent.
    //
    function reportBounds(): void {
        const bounds = map.getBounds();
        onBoundsChange({
            northLat: bounds.getNorth(),
            southLat: bounds.getSouth(),
            westLng: bounds.getWest(),
            eastLng: bounds.getEast(),
            zoom: map.getZoom(),
        });
    }

    //
    // Capture initial bounds once the map is mounted and ready.
    //
    useEffect(() => {
        map.whenReady(reportBounds);
    }, []);

    useMapEvents({
        moveend: reportBounds,
        zoomend: reportBounds,
    });

    return null;
}

//
// The map view component showing photos with GPS coordinates on an interactive map.
// Only renders markers within the current viewport for performance.
//
export function MapView() {
    const { searchedItems } = useGallery();
    const { mode, systemMode } = useColorScheme();

    //
    // The theme the page is drawn in. The map's tiles are pictures that cannot take the theme's
    // colours, so the dark theme loads CARTO's dark tiles in place of its light ones.
    //
    const isDark = (mode === 'system' ? systemMode : mode) === 'dark';
    const { assetUrl } = useAssetDatabase();
    const navigate = useNavigate();

    //
    // Builds a thumbnail URL for an asset using the REST API.
    //
    function thumbUrl(item: IGalleryItem): string {
        return assetUrl(item._id, "thumb");
    }

    //
    // Current map viewport bounds (null until the map fires its first event).
    //
    const [mapBounds, setMapBounds] = useState<IMapBounds | null>(null);

    //
    // The cluster currently selected for the modal, if any.
    //
    const [selectedCluster, setSelectedCluster] = useState<ICluster | undefined>(undefined);

    //
    // All items with GPS coordinates.
    //
    const geoItems = searchedItems().filter(item => item.coordinates !== undefined);

    //
    // Items visible within the current viewport.
    //
    const visibleItems = mapBounds
        ? geoItems.filter(item => isInBounds(item.coordinates!.lat, item.coordinates!.lng, mapBounds))
        : [];

    //
    // Clusters computed from visible items at the current zoom level.
    //
    const clusters = mapBounds
        ? clusterItems(visibleItems, mapBounds.zoom)
        : [];

    //
    // Handles clicking a single-photo marker — opens the asset view within the map page.
    //
    function onSinglePhotoClick(item: IGalleryItem): void {
        navigate(`/map/${item._id}`);
    }

    //
    // Handles clicking a cluster marker.
    //
    function onClusterClick(cluster: ICluster): void {
        setSelectedCluster(cluster);
    }

    return (
        <div className="photosphere-map" style={{ width: '100%', height: '100%' }}>
            <MapContainer
                center={[20, 0]}
                zoom={3}
                style={{
                    width: '100%',
                    height: '100%',
                    background: 'var(--color-map-water)',
                }}
            >
                <TileLayer
                    key={isDark ? 'dark' : 'light'}
                    attribution='&copy; <a href="https://www.openstreetmap.org/copyright">OpenStreetMap</a> contributors &copy; <a href="https://carto.com/attributions">CARTO</a>'
                    url={isDark
                        ? "https://{s}.basemaps.cartocdn.com/dark_all/{z}/{x}/{y}{r}.png"
                        : "https://{s}.basemaps.cartocdn.com/rastertiles/voyager/{z}/{x}/{y}{r}.png"}
                />

                <MapEvents onBoundsChange={setMapBounds} />

                {clusters.map((cluster, index) => {
                    if (cluster.items.length === 1) {
                        const item = cluster.items[0];
                        return (
                            <Marker
                                key={`single-${item._id}`}
                                position={[cluster.lat, cluster.lng]}
                                icon={createSinglePhotoIcon(item, thumbUrl)}
                                eventHandlers={{
                                    click: () => onSinglePhotoClick(item),
                                }}
                            />
                        );
                    }

                    return (
                        <Marker
                            key={`cluster-${index}`}
                            position={[cluster.lat, cluster.lng]}
                            icon={createClusterIcon(cluster, thumbUrl)}
                            eventHandlers={{
                                click: () => onClusterClick(cluster),
                            }}
                        />
                    );
                })}
            </MapContainer>

            {selectedCluster && (
                <ClusterModal
                    items={selectedCluster.items}
                    lat={selectedCluster.lat}
                    lng={selectedCluster.lng}
                    onClose={() => setSelectedCluster(undefined)}
                />
            )}
        </div>
    );
}
