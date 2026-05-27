import React from "react";
import { FilmStrip } from "../../components/film-strip";
import { MockProviders, mockAssetDatabase, mockAssets } from "../mocks";
import type { IStory } from "../types";

//
// Items used by the film-strip story.
//
const items = mockAssets(8);

//
// Stories for the FilmStrip.
//
export const stories: IStory[] = [
    {
        id: "film-strip/default",
        name: "Film Strip",
        category: "Components",
        render: () => (
            <MockProviders assetDatabase={mockAssetDatabase(items)}>
                <FilmStrip asset={items[3]} />
            </MockProviders>
        ),
    },
];
