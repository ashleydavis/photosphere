import React from "react";
import { AssetView } from "../../components/asset-view";
import { MockProviders, mockAssetDatabase, mockGalleryItem, noOp } from "../mocks";
import { GalleryItemContextProvider } from "../../context/gallery-item-context";
import type { IStory } from "../types";

//
// Image-asset variant used by the image story.
//
const imageItem = mockGalleryItem({ _id: "av-image", origFileName: "photo.jpg", contentType: "image/jpeg" });

//
// Video-asset variant used by the video story.
//
const videoItem = mockGalleryItem({ _id: "av-video", origFileName: "clip.mp4", contentType: "video/mp4" });

//
// Stories for the AssetView component.
//
export const stories: IStory[] = [
    {
        id: "asset-view/image",
        name: "Asset View (image)",
        category: "Components",
        render: () => (
            <MockProviders assetDatabase={mockAssetDatabase([imageItem])}>
                <GalleryItemContextProvider assetId={imageItem._id}>
                    <AssetView onClose={noOp} onNext={noOp} onPrev={noOp} />
                </GalleryItemContextProvider>
            </MockProviders>
        ),
    },
    {
        id: "asset-view/video",
        name: "Asset View (video)",
        category: "Components",
        render: () => (
            <MockProviders assetDatabase={mockAssetDatabase([videoItem])}>
                <GalleryItemContextProvider assetId={videoItem._id}>
                    <AssetView onClose={noOp} onNext={noOp} onPrev={noOp} />
                </GalleryItemContextProvider>
            </MockProviders>
        ),
    },
];
