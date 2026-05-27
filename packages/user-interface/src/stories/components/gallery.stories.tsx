import React from "react";
import { Gallery } from "../../components/gallery";
import { MockProviders, mockAssetDatabase, mockAssets } from "../mocks";
import type { IStory } from "../types";

//
// Stories for the Gallery component.
//
export const stories: IStory[] = [
    {
        id: "gallery-component/empty",
        name: "Gallery (empty)",
        category: "Components",
        render: () => (
            <MockProviders assetDatabase={mockAssetDatabase([])}>
                <Gallery />
            </MockProviders>
        ),
    },
    {
        id: "gallery-component/populated",
        name: "Gallery (populated)",
        category: "Components",
        render: () => (
            <MockProviders assetDatabase={mockAssetDatabase(mockAssets(24))}>
                <Gallery />
            </MockProviders>
        ),
    },
];
