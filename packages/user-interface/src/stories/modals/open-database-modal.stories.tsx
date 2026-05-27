import React from "react";
import { OpenDatabaseModal } from "../../components/open-database-modal";
import { MockProviders, noOp } from "../mocks";
import type { IStory } from "../types";

//
// Stories for the OpenDatabaseModal.
//
export const stories: IStory[] = [
    {
        id: "open-database-modal/open",
        name: "Open Database",
        category: "Modals",
        render: () => (
            <MockProviders>
                <OpenDatabaseModal open={true} onClose={noOp} />
            </MockProviders>
        ),
    },
];
