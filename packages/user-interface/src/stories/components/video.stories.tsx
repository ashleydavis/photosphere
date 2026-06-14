import React from "react";
import { Video } from "../../components/video";
import { MockProviders, mockAssetDatabase, mockGalleryItem } from "../mocks";
import type { IStory } from "../types";

//
// Item used by the video story.
//
const item = mockGalleryItem({ _id: "video-1", origFileName: "clip.mp4", contentType: "video/mp4" });

//
// Stories for the Video component. The video element is absolutely positioned
// and would otherwise cover the whole viewer, so it is hosted in a sized,
// relatively-positioned box that keeps it within the preview pane.
//
export const stories: IStory[] = [
    {
        id: "video/default",
        name: "Video",
        category: "Components",
        render: () => (
            <MockProviders assetDatabase={mockAssetDatabase([item])}>
                <div style={{ position: "relative", width: "100%", height: "400px", overflow: "hidden" }}>
                    <Video asset={item} />
                </div>
            </MockProviders>
        ),
    },
];
