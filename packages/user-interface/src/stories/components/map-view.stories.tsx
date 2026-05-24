import React from "react";
import { MapView } from "../../pages/map/map-view";
import { MockProviders, mockAssetDatabase, mockGalleryItem } from "../mocks";
import type { IStory } from "../types";

//
// Geo-tagged items used by the map-view story.
//
const items = [
    mockGalleryItem({ _id: "mv-1", origFileName: "a.jpg", coordinates: { lat: -33.86, lng: 151.21 } }),
    mockGalleryItem({ _id: "mv-2", origFileName: "b.jpg", coordinates: { lat: 51.5, lng: -0.12 } }),
];

//
// Stories for the MapView component.
//
export const stories: IStory[] = [
    {
        id: "map-view/default",
        name: "Map View",
        category: "Components",
        render: () => (
            <MockProviders assetDatabase={mockAssetDatabase(items)}>
                <div style={{ width: "100%", height: "400px" }}>
                    <MapView />
                </div>
            </MockProviders>
        ),
    },
];
