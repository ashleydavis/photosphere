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
// Stories for the Carousel.
//
export const stories: IStory[] = [
    {
        id: "carousel/single-image",
        name: "Carousel (single image)",
        category: "Components",
        render: () => (
            <MockProviders assetDatabase={mockAssetDatabase([singleItem])}>
                <Carousel asset={singleItem} />
            </MockProviders>
        ),
    },
    {
        id: "carousel/multiple-images",
        name: "Carousel (multiple images)",
        category: "Components",
        render: () => (
            <MockProviders assetDatabase={mockAssetDatabase(multipleItems)}>
                <Carousel asset={multipleItems[2]} />
            </MockProviders>
        ),
    },
];
