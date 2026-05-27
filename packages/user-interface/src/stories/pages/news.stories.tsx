import React from "react";
import { NewsPage } from "../../pages/news";
import { MockProviders } from "../mocks";
import type { IStory } from "../types";

//
// Stories for the News page.
//
export const stories: IStory[] = [
    {
        id: "news-page/default",
        name: "News",
        category: "Pages",
        render: () => (
            <MockProviders>
                <NewsPage />
            </MockProviders>
        ),
    },
];
