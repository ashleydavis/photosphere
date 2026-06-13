import React from "react";
import { DatabaseSummaryPage } from "../../pages/database-summary";
import { RealDatabaseProviders } from "../mocks";
import type { IStory } from "../types";

//
// Stories for the Database Summary page.
//
// Uses RealDatabaseProviders because the summary is computed by the
// get-database-summary task from a real merkle tree. A mock database has no
// merkle tree, so the task fails with "Failed to load merkle tree".
//
export const stories: IStory[] = [
    {
        id: "database-summary-page/default",
        name: "Database Summary",
        category: "Pages",
        render: () => (
            <RealDatabaseProviders>
                <DatabaseSummaryPage />
            </RealDatabaseProviders>
        ),
    },
];
