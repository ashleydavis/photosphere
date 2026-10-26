import React from "react";
import { ToolsPage } from "../../pages/tools";
import { MockProviders } from "../mocks";
import type { IStory } from "../types";

//
// Stories for the Tools page.
//
export const stories: IStory[] = [
    {
        id: "tools-page/default",
        name: "Tools",
        category: "Pages",
        render: () => (
            <MockProviders>
                <ToolsPage />
            </MockProviders>
        ),
    },
];
