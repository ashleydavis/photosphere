import React from "react";
import { ShareDatabaseDialog } from "../../components/share-database-dialog";
import { MockProviders, noOp } from "../mocks";
import type { IStory } from "../types";
import type { IDatabaseEntry } from "../../context/platform-context";

//
// Sample entry used by the share-database dialog story.
//
const sampleEntry: IDatabaseEntry = {
    name: "Family Photos",
    description: "Holiday and family albums",
    path: "/photos/family",
};

//
// Stories for the ShareDatabaseDialog.
//
export const stories: IStory[] = [
    {
        id: "share-database-dialog/open",
        name: "Share Database",
        category: "Dialogs",
        render: () => (
            <MockProviders>
                <ShareDatabaseDialog open={true} entry={sampleEntry} onClose={noOp} />
            </MockProviders>
        ),
    },
];
