import React from "react";
import { ConfigurationPage } from "../../pages/configuration";
import { MockProviders } from "../mocks";
import type { IStory } from "../types";

//
// Stories for the Configuration page.
//
export const stories: IStory[] = [
    {
        id: "configuration-page/default",
        name: "Configuration",
        category: "Pages",
        render: () => (
            <MockProviders>
                <ConfigurationPage />
            </MockProviders>
        ),
    },
];
