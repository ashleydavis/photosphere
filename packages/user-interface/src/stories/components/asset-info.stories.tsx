import React from "react";
import { AssetInfo } from "../../pages/gallery/components/asset-info";
import { MockProviders, mockAssetDatabase, mockGalleryItem, noOp } from "../mocks";
import { GalleryItemContextProvider } from "../../context/gallery-item-context";
import type { IStory } from "../types";

//
// Selected asset used by the asset-info story.
//
const item = mockGalleryItem({ _id: "asset-info-1", origFileName: "info.jpg" });

//
// Stories for the AssetInfo component.
//
export const stories: IStory[] = [
    {
        id: "asset-info/default",
        name: "Asset Info",
        category: "Components",
        render: () => (
            <MockProviders assetDatabase={mockAssetDatabase([item])}>
                <GalleryItemContextProvider assetId={item._id}>
                    <AssetInfo onClose={noOp} onDeleted={noOp} onLabelSearch={noOp} />
                </GalleryItemContextProvider>
            </MockProviders>
        ),
    },
];
