import React from "react";
import { GalleryLayout } from "../../components/gallery-layout";
import { MockProviders, mockAssetDatabase, mockAssets, noOp } from "../mocks";
import type { IStory } from "../types";

//
// Stories for the GalleryLayout component.
//
export const stories: IStory[] = [
    {
        id: "gallery-layout/default",
        name: "Gallery Layout",
        category: "Components",
        render: () => (
            <MockProviders assetDatabase={mockAssetDatabase(mockAssets(12))}>
                <div style={{ position: "relative", width: "100%", height: "400px" }}>
                    <GalleryLayout onItemClick={noOp} />
                </div>
            </MockProviders>
        ),
    },
];
