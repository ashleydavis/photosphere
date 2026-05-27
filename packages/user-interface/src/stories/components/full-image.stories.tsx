import React from "react";
import { FullImage } from "../../components/full-image";
import { MockProviders, mockAssetDatabase, mockGalleryItem } from "../mocks";
import type { IStory } from "../types";

//
// Item used by the full-image story.
//
const item = mockGalleryItem({ _id: "full-image-1" });

//
// Stories for the FullImage component.
//
export const stories: IStory[] = [
    {
        id: "full-image/default",
        name: "Full Image",
        category: "Components",
        render: () => (
            <MockProviders assetDatabase={mockAssetDatabase([item])}>
                <FullImage asset={item} />
            </MockProviders>
        ),
    },
];
