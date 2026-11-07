import React from "react";
import { DatabaseSummaryDialog } from "../../components/database-summary-dialog";
import { RealDatabaseProviders, noOp } from "../mocks";
import type { IStory } from "../types";

//
// Stories for the database summary dialog, the navbar photo count's destination.
//
// Uses RealDatabaseProviders for the same reason the Database Summary page story does: the summary
// is computed by the get-database-summary task from a real merkle tree, and a mock database has
// none, so the task fails with "Failed to load merkle tree".
//
export const stories: IStory[] = [
    {
        id: "database-summary-dialog/default",
        name: "Database Summary Dialog",
        category: "Components",
        render: () => (
            <RealDatabaseProviders>
                <DatabaseSummaryDialog open={true} onClose={noOp} />
            </RealDatabaseProviders>
        ),
    },
];
