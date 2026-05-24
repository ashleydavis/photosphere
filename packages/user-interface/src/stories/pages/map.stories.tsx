import React from "react";
import { MapPage } from "../../pages/map/map-page";
import { MockProviders, mockAssetDatabase, mockGalleryItem } from "../mocks";
import type { IStory } from "../types";

//
// Builds a small set of geo-tagged assets for the map story.
//
function geoTaggedAssets() {
    return [
        mockGalleryItem({ _id: "geo-1", origFileName: "sydney.jpg", coordinates: { lat: -33.8688, lng: 151.2093 } }),
        mockGalleryItem({ _id: "geo-2", origFileName: "london.jpg", coordinates: { lat: 51.5074, lng: -0.1278 } }),
        mockGalleryItem({ _id: "geo-3", origFileName: "nyc.jpg", coordinates: { lat: 40.7128, lng: -74.006 } }),
    ];
}

//
// Stories for the Map page.
//
export const stories: IStory[] = [
    {
        id: "map-page/default",
        name: "Map",
        category: "Pages",
        render: () => (
            <MockProviders assetDatabase={mockAssetDatabase(geoTaggedAssets())}>
                <MapPage />
            </MockProviders>
        ),
    },
];
