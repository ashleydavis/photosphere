import React from "react";
import { AssetInfo } from "../../pages/gallery/components/asset-info";
import { RealDatabaseProviders, WithRealAssets, noOp } from "../mocks";
import { GalleryItemContextProvider } from "../../context/gallery-item-context";
import type { IStory } from "../types";

//
// Stories for the AssetInfo component. Uses the 50-assets fixture so the panel
// shows a real asset's preview and metadata instead of a grey placeholder.
//
export const stories: IStory[] = [
    {
        id: "asset-info/default",
        name: "Asset Info",
        category: "Components",
        render: () => (
            <RealDatabaseProviders>
                <WithRealAssets count={1}>
                    {assets => (
                        <GalleryItemContextProvider assetId={assets[0]._id}>
                            <AssetInfo onClose={noOp} onDeleted={noOp} onLabelSearch={noOp} />
                        </GalleryItemContextProvider>
                    )}
                </WithRealAssets>
            </RealDatabaseProviders>
        ),
    },
];
