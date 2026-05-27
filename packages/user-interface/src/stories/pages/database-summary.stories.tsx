import React from "react";
import { DatabaseSummaryPage } from "../../pages/database-summary";
import { MockProviders, mockAssetDatabase, mockAssets } from "../mocks";
import type { IStory } from "../types";

//
// Stories for the Database Summary page.
//
export const stories: IStory[] = [
    {
        id: "database-summary-page/default",
        name: "Database Summary",
        category: "Pages",
        render: () => (
            <MockProviders assetDatabase={mockAssetDatabase(mockAssets(12))}>
                <DatabaseSummaryPage />
            </MockProviders>
        ),
    },
];
