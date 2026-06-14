import React from "react";
import { AssetView } from "../../components/asset-view";
import { MockProviders, RealDatabaseProviders, StoryModalLauncher, WithRealAssets, mockAssetDatabase, mockGalleryItem, noOp } from "../mocks";
import { GalleryItemContextProvider } from "../../context/gallery-item-context";
import type { IStory } from "../types";

//
// Video-asset variant used by the video story.
//
const videoItem = mockGalleryItem({ _id: "av-video", origFileName: "clip.mp4", contentType: "video/mp4" });

//
// Stories for the AssetView component. AssetView is a full-screen overlay, so
// each story opens it from a button and wires its close action to dismiss it,
// returning the story browser to view.
//
export const stories: IStory[] = [
    {
        id: "asset-view/image",
        name: "Asset View (image)",
        category: "Components",
        render: () => (
            <RealDatabaseProviders>
                <StoryModalLauncher label="asset view">
                    {(open, onClose) => open
                        ? (
                            <WithRealAssets count={1}>
                                {([asset]) => (
                                    <GalleryItemContextProvider assetId={asset._id}>
                                        <AssetView onClose={onClose} onNext={noOp} onPrev={noOp} />
                                    </GalleryItemContextProvider>
                                )}
                            </WithRealAssets>
                        )
                        : null
                    }
                </StoryModalLauncher>
            </RealDatabaseProviders>
        ),
    },
    {
        id: "asset-view/video",
        name: "Asset View (video)",
        category: "Components",
        render: () => (
            <MockProviders assetDatabase={mockAssetDatabase([videoItem])}>
                <StoryModalLauncher label="asset view (video)">
                    {(open, onClose) => open
                        ? (
                            <GalleryItemContextProvider assetId={videoItem._id}>
                                <AssetView onClose={onClose} onNext={noOp} onPrev={noOp} />
                            </GalleryItemContextProvider>
                        )
                        : null
                    }
                </StoryModalLauncher>
            </MockProviders>
        ),
    },
];
