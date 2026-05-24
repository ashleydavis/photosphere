import React from "react";
import { AboutPage } from "../../pages/about";
import { MockProviders } from "../mocks";
import type { IStory } from "../types";

//
// Stories for the About page.
//
export const stories: IStory[] = [
    {
        id: "about-page/default",
        name: "About",
        category: "Pages",
        render: () => (
            <MockProviders>
                <AboutPage />
            </MockProviders>
        ),
    },
];
