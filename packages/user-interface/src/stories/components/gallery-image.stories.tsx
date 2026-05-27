import React from "react";
import { GalleryImage } from "../../components/gallery-image";
import { MockProviders, mockGalleryItem, mockAssetDatabase, noOp } from "../mocks";
import type { IStory } from "../types";

//
// Item used by both gallery-image stories.
//
const item = mockGalleryItem({ _id: "gallery-image-1" });

//
// Stories for the GalleryImage component.
//
export const stories: IStory[] = [
    {
        id: "gallery-image/default",
        name: "Gallery Image (default)",
        category: "Components",
        render: () => (
            <MockProviders assetDatabase={mockAssetDatabase([item])}>
                <div style={{ position: "relative", width: "200px", height: "200px" }}>
                    <GalleryImage item={item} onClick={noOp} x={0} y={0} width={200} height={200} />
                </div>
            </MockProviders>
        ),
    },
    {
        id: "gallery-image/selected",
        name: "Gallery Image (selected)",
        category: "Components",
        render: () => (
            <MockProviders assetDatabase={mockAssetDatabase([item])}>
                <div style={{ position: "relative", width: "200px", height: "200px" }}>
                    <GalleryImage item={item} onClick={noOp} x={0} y={0} width={200} height={200} />
                </div>
            </MockProviders>
        ),
    },
];
