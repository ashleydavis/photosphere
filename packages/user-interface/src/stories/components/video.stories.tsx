import React from "react";
import { Video } from "../../components/video";
import { MockProviders, mockAssetDatabase, mockGalleryItem } from "../mocks";
import type { IStory } from "../types";

//
// Item used by the video story.
//
const item = mockGalleryItem({ _id: "video-1", origFileName: "clip.mp4", contentType: "video/mp4" });

//
// Stories for the Video component.
//
export const stories: IStory[] = [
    {
        id: "video/default",
        name: "Video",
        category: "Components",
        render: () => (
            <MockProviders assetDatabase={mockAssetDatabase([item])}>
                <Video asset={item} />
            </MockProviders>
        ),
    },
];
