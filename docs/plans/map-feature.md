# Plan: Add Map Tab with React Leaflet

## Context
The user wants a new "Map" tab in the Photosphere app that shows photos on a geographic map (using React Leaflet + OpenStreetMap). Only photos with GPS coordinates should appear. Nearby photos should be auto-clustered based on zoom level. Cluster pins should show a "many photos" indicator; single pins should show a preview of the photo. Clicking a cluster pin opens a popup modal gallery for those photos.

`IGalleryItem` currently lacks the `coordinates` field (present in `IAsset` from the `defs` package but not surfaced in the UI type). Assets do carry coordinates at runtime (since `IAsset` is assigned into `IGalleryItemMap`), but the TypeScript type doesn't declare it.

## Key Files

### Modified
- `packages/user-interface/src/lib/gallery-item.ts` — add `coordinates` field
- `packages/user-interface/src/main.tsx` — add `/map` route
- `packages/user-interface/src/components/navbar.tsx` — add Map NavLink

### Created
- `packages/user-interface/src/pages/map/map-page.tsx` — page wrapper (mirrors gallery.tsx pattern)
- `packages/user-interface/src/pages/map/map-view.tsx` — map component with clustering logic
- `packages/user-interface/src/pages/map/cluster-modal.tsx` — modal gallery for clustered photos

## Dependencies to Install (in `packages/user-interface/`)
```
bun add react-leaflet leaflet @types/leaflet
```
OpenStreetMap tiles are used (free, no API key).

## Implementation Steps

### Step 1 — Add `coordinates` to `IGalleryItem`
In `gallery-item.ts`, add after `location?`:
```typescript
//
// The GPS coordinates of the asset, if known.
//
coordinates?: {
    lat: number;
    lng: number;
};
```

### Step 2 — Install packages
```
cd packages/user-interface && bun add react-leaflet leaflet @types/leaflet
```

### Step 3 — Create `map-page.tsx`
Mirrors `gallery.tsx`. Shows "No database loaded" state when `!databasePath`, otherwise renders `<MapView />`.

### Step 4 — Create `map-view.tsx`

Key pieces:
- Import `leaflet/dist/leaflet.css`
- Use `useGallery().allItems()` to get all assets; filter to those with `coordinates`
- Render `<MapContainer>` + `<TileLayer>` (OSM)
- Implement zoom-based lat/lng grid clustering via `useMapEvents` + React state
- Cluster algorithm: `gridSize = 360 / 2^(zoom+1)`, group by `floor(lat/gridSize), floor(lng/gridSize)`
- Single-photo pins: `L.divIcon` with the `micro` base64 as a circular thumbnail
- Cluster pins: `L.divIcon` with top micro thumbnail + count badge overlay
- Clicking single pin: navigate to `/cloud/${assetId}` to open asset view
- Clicking cluster pin: open `ClusterModal` with those items

**Clustering logic:**
```typescript
function clusterItems(items: IGalleryItem[], zoom: number): ICluster[] {
    const gridSize = 360 / Math.pow(2, zoom + 1);
    const cells = new Map<string, IGalleryItem[]>();
    for (const item of items) {
        if (!item.coordinates) continue;
        const cellLat = Math.floor(item.coordinates.lat / gridSize);
        const cellLng = Math.floor(item.coordinates.lng / gridSize);
        const key = `${cellLat},${cellLng}`;
        if (!cells.has(key)) {
            cells.set(key, []);
        }
        cells.get(key)!.push(item);
    }
    return Array.from(cells.entries()).map(([, cellItems]) => ({
        lat: cellItems.reduce((sum, item) => sum + item.coordinates!.lat, 0) / cellItems.length,
        lng: cellItems.reduce((sum, item) => sum + item.coordinates!.lng, 0) / cellItems.length,
        items: cellItems,
    }));
}
```

### Step 5 — Create `cluster-modal.tsx`
MUI Joy `Modal` showing a scrollable grid of photos from the cluster.
- `micro` thumbnails in a 4-column grid
- Each photo navigates to `/cloud/${item._id}` on click
- Title: "X photos at this location"

### Step 6 — Add Route in `main.tsx`
Add `/map` route pointing to `MapPage`.

### Step 7 — Add Navbar Tab in `navbar.tsx`
Add Map NavLink between Gallery and About tabs using `fa-solid fa-map` icon.

## Interfaces

```typescript
interface ICluster {
    lat: number;
    lng: number;
    items: IGalleryItem[];
}
```

## Verification
1. `bun run compile` — TypeScript must compile cleanly
2. `bun run dev:web` — open browser, click "Map" tab
3. Open a database with GPS-tagged photos — pins appear on map
4. Zoom in — clusters split into individual pins
5. Click a cluster pin — modal opens with photo grid
6. Click a single pin — navigates to that photo in gallery view
7. `bun run test` — all tests pass
