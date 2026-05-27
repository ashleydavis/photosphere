import React from "react";
import { RemoveDatabaseDialog } from "../../components/remove-database-dialog";
import { MockProviders, noOp } from "../mocks";
import type { IStory } from "../types";
import type { IDatabaseEntry } from "../../context/platform-context";

//
// Sample entry used by the remove-database dialog story.
//
const sampleEntry: IDatabaseEntry = {
    name: "Old Backup",
    description: "Archived 2020",
    path: "/photos/old-backup",
};

//
// Stories for the RemoveDatabaseDialog.
//
export const stories: IStory[] = [
    {
        id: "remove-database-dialog/open",
        name: "Remove Database",
        category: "Dialogs",
        render: () => (
            <MockProviders>
                <RemoveDatabaseDialog open={true} entry={sampleEntry} onClose={noOp} />
            </MockProviders>
        ),
    },
];
