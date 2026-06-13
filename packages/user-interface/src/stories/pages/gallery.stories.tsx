import React from "react";
import { GalleryPage } from "../../pages/gallery/gallery";
import { MockProviders, RealDatabaseProviders, mockAssetDatabase } from "../mocks";
import type { IStory } from "../types";

//
// Builds an asset database mock fixed in a "loading" state for the loading variant.
//
function loadingAssetDatabase() {
    const database = mockAssetDatabase();
    return { ...database, isLoading: true };
}

//
// Stories for the Gallery page.
//
export const stories: IStory[] = [
    {
        id: "gallery-page/empty",
        name: "Gallery (empty)",
        category: "Pages",
        render: () => (
            <MockProviders assetDatabase={mockAssetDatabase([])}>
                <GalleryPage />
            </MockProviders>
        ),
    },
    {
        id: "gallery-page/with-assets",
        name: "Gallery (with assets)",
        category: "Pages",
        render: () => (
            <RealDatabaseProviders>
                <GalleryPage />
            </RealDatabaseProviders>
        ),
    },
    {
        id: "gallery-page/loading",
        name: "Gallery (loading)",
        category: "Pages",
        render: () => (
            <MockProviders assetDatabase={loadingAssetDatabase()}>
                <GalleryPage />
            </MockProviders>
        ),
    },
];
