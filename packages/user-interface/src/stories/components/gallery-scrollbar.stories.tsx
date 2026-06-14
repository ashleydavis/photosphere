import React, { useRef } from "react";
import { GalleryScrollbar } from "../../components/gallery-scrollbar";
import { MockProviders, noOp } from "../mocks";
import type { IStory } from "../types";
import type { IGalleryLayout } from "../../lib/create-layout";

//
// Layout shell used by the gallery-scrollbar story. The scrollbar only reads
// galleryHeight to size and place its thumb, so a tall gallery (relative to the
// 300px host below) is enough to make the scrollbar appear instead of rendering
// nothing.
//
const layout: IGalleryLayout = {
    rows: [],
    galleryHeight: 2000,
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
