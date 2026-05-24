import React from "react";
import { RightSidebar } from "../../components/right-sidebar";
import { MockProviders, mockAssetDatabase, mockGalleryItem, noOp } from "../mocks";
import { GalleryItemContextProvider } from "../../context/gallery-item-context";
import type { IStory } from "../types";

//
// Selected asset used by the right-sidebar story.
//
const selectedAsset = mockGalleryItem({ _id: "right-sidebar-1", origFileName: "selected.jpg" });

//
// Stories for the RightSidebar.
//
export const stories: IStory[] = [
    {
        id: "right-sidebar/open",
        name: "Right Sidebar",
        category: "Components",
        render: () => (
            <MockProviders assetDatabase={mockAssetDatabase([selectedAsset])}>
                <GalleryItemContextProvider assetId={selectedAsset._id}>
                    <RightSidebar sidebarOpen={true} setSidebarOpen={noOp} />
                </GalleryItemContextProvider>
            </MockProviders>
        ),
    },
];
