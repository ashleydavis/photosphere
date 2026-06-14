import React from "react";
import { FilmStrip } from "../../components/film-strip";
import { MockProviders, mockAssetDatabase, mockAssets } from "../mocks";
import type { IStory } from "../types";

//
// Items used by the film-strip story. Mock items carry a real micro thumbnail,
// so the side frames show a picture instead of empty boxes.
//
const items = mockAssets(8);

//
// Stories for the FilmStrip. The frames are absolutely positioned, so they are
// hosted in a sized, relatively-positioned box.
//
export const stories: IStory[] = [
    {
        id: "film-strip/default",
        name: "Film Strip",
        category: "Components",
        render: () => (
            <MockProviders assetDatabase={mockAssetDatabase(items)}>
                <div style={{ position: "relative", width: "100%", height: "200px" }}>
                    <FilmStrip asset={items[3]} />
                </div>
            </MockProviders>
        ),
    },
];
