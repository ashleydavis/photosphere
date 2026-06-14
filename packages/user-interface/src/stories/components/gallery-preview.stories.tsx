import React from "react";
import { GalleryPreview } from "../../components/gallery-preview";
import { MockProviders, mockGalleryItem } from "../mocks";
import type { IStory } from "../types";

//
// Item used by the gallery-preview story. GalleryPreview is a low-fidelity
// placeholder shown during fast scrolling: it renders only the asset's dominant
// colour (no image), so the item is given a clear colour to make the swatch
// obvious rather than looking empty.
//
const item = mockGalleryItem({ _id: "preview-1", color: [70, 110, 165] });

//
// Stories for the GalleryPreview component.
//
export const stories: IStory[] = [
    {
        id: "gallery-preview/default",
        name: "Gallery Preview",
        category: "Components",
        render: () => (
            <MockProviders>
                <div style={{ position: "relative", width: "300px", height: "200px" }}>
                    <GalleryPreview item={item} x={0} y={0} width={300} height={200} />
                </div>
            </MockProviders>
        ),
    },
];
