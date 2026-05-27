import React, { useRef } from "react";
import { GalleryScrollbar } from "../../components/gallery-scrollbar";
import { MockProviders, noOp } from "../mocks";
import type { IStory } from "../types";
import type { IGalleryLayout } from "../../lib/create-layout";

//
// Empty layout shell used by the gallery-scrollbar story.
//
const layout: IGalleryLayout = {
    rows: [],
    galleryHeight: 0,
};

//
// Renders the GalleryScrollbar inside a host container with a forwarded ref.
//
function GalleryScrollbarHost() {
    const containerRef = useRef<HTMLDivElement>(null);
    return (
        <div ref={containerRef} style={{ position: "relative", width: "20px", height: "300px" }}>
            <GalleryScrollbar scrollContainerRef={containerRef} galleryLayout={layout} scrollTo={noOp} />
        </div>
    );
}

//
// Stories for the GalleryScrollbar component.
//
export const stories: IStory[] = [
    {
        id: "gallery-scrollbar/default",
        name: "Gallery Scrollbar",
        category: "Components",
        render: () => (
            <MockProviders>
                <GalleryScrollbarHost />
            </MockProviders>
        ),
    },
];
