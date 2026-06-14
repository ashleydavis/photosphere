import React from "react";
import { ShareDatabaseDialog } from "../../components/share-database-dialog";
import { MockProviders, StoryModalLauncher } from "../mocks";
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
                <StoryModalLauncher label="share database dialog">
                    {(open, onClose) => <ShareDatabaseDialog open={open} entry={sampleEntry} onClose={onClose} />}
                </StoryModalLauncher>
            </MockProviders>
        ),
    },
];
