import React from "react";
import { AddDatabaseModal } from "../../components/add-database-modal";
import { MockProviders, noOp } from "../mocks";
import type { IStory } from "../types";

//
// Stories for the AddDatabaseModal.
//
export const stories: IStory[] = [
    {
        id: "add-database-modal/open",
        name: "Add Database",
        category: "Modals",
        render: () => (
            <MockProviders>
                <AddDatabaseModal open={true} onClose={noOp} />
            </MockProviders>
        ),
    },
];
