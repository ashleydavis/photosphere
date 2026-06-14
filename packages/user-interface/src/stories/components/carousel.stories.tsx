import React from "react";
import { Carousel } from "../../components/carousel";
import { MockProviders, mockAssetDatabase, mockAssets, mockGalleryItem } from "../mocks";
import type { IStory } from "../types";

//
// Single-asset variant used by the single-image story.
//
const singleItem = mockGalleryItem({ _id: "carousel-single", origFileName: "alone.jpg" });

//
// A small set of assets used by the multiple-images story.
//
const multipleItems = mockAssets(5);

//
// Stories for the Carousel. Uses mock items whose micro thumbnail is a real
// image, so the centre and side frames all show a picture. The carousel items
// are absolutely positioned, so each story hosts them in a sized,
// relatively-positioned box.
//
export const stories: IStory[] = [
    {
        id: "carousel/single-image",
        name: "Carousel (single image)",
        category: "Components",
        render: () => (
            <MockProviders assetDatabase={mockAssetDatabase([singleItem])}>
                <div style={{ position: "relative", width: "100%", height: "400px", overflow: "hidden" }}>
                    <Carousel asset={singleItem} />
                </div>
            </MockProviders>
        ),
    },
    {
        id: "carousel/multiple-images",
        name: "Carousel (multiple images)",
        category: "Components",
        render: () => (
            <MockProviders assetDatabase={mockAssetDatabase(multipleItems)}>
                <div style={{ position: "relative", width: "100%", height: "400px", overflow: "hidden" }}>
                    <Carousel asset={multipleItems[2]} />
                </div>
            </MockProviders>
        ),
    },
];
