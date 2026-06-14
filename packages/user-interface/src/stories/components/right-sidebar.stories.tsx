import React from "react";
import { RightSidebar } from "../../components/right-sidebar";
import { RealDatabaseProviders, WithRealAssets, noOp } from "../mocks";
import { GalleryItemContextProvider } from "../../context/gallery-item-context";
import type { IStory } from "../types";

//
// Stories for the RightSidebar. Uses the 50-assets fixture so the selected
// asset shows a real preview instead of a grey placeholder.
//
export const stories: IStory[] = [
    {
        id: "right-sidebar/open",
        name: "Right Sidebar",
        category: "Components",
        render: () => (
            <RealDatabaseProviders>
                <WithRealAssets count={1}>
                    {assets => (
                        <GalleryItemContextProvider assetId={assets[0]._id}>
                            <RightSidebar sidebarOpen={true} setSidebarOpen={noOp} />
                        </GalleryItemContextProvider>
                    )}
                </WithRealAssets>
            </RealDatabaseProviders>
        ),
    },
];
