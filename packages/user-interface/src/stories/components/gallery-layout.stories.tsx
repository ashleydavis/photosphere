import React from "react";
import { GalleryLayout } from "../../components/gallery-layout";
import { RealDatabaseProviders, noOp } from "../mocks";
import type { IStory } from "../types";

//
// Stories for the GalleryLayout component. Uses the 50-assets fixture so the
// layout fills with real photos instead of an empty/grey grid.
//
export const stories: IStory[] = [
    {
        id: "gallery-layout/default",
        name: "Gallery Layout",
        category: "Components",
        render: () => (
            <RealDatabaseProviders>
                <div style={{ position: "relative", width: "100%", height: "400px" }}>
                    <GalleryLayout onItemClick={noOp} />
                </div>
            </RealDatabaseProviders>
        ),
    },
];
