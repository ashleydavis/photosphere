import React from "react";
import { OpenDatabaseModal } from "../../components/open-database-modal";
import { MockProviders, StoryModalLauncher, mockPlatform } from "../mocks";
import type { IStory } from "../types";
import type { IDatabaseEntry } from "../../context/platform-context";

//
// Sample databases shown by the "with databases" variant.
//
const sampleDatabases: IDatabaseEntry[] = [
    { name: "Family Photos", description: "Holiday and family albums", path: "/photos/family" },
    { name: "Work Archive", description: "Project screenshots", path: "/photos/work" },
    { name: "Old Backup", description: "Archived 2020", path: "/photos/old-backup" },
];

//
// Stories for the OpenDatabaseModal: one populated with databases and one empty.
//
export const stories: IStory[] = [
    {
        id: "open-database-modal/with-databases",
        name: "Open Database (with databases)",
        category: "Modals",
        render: () => {
            const platform = mockPlatform();
            platform.getDatabases = async () => sampleDatabases;
            return (
                <MockProviders platform={platform}>
                    <StoryModalLauncher label="open database modal (with databases)">
                        {(open, onClose) => <OpenDatabaseModal open={open} onClose={onClose} />}
                    </StoryModalLauncher>
                </MockProviders>
            );
        },
    },
    {
        id: "open-database-modal/empty",
        name: "Open Database (empty)",
        category: "Modals",
        render: () => (
            <MockProviders>
                <StoryModalLauncher label="open database modal (empty)">
                    {(open, onClose) => <OpenDatabaseModal open={open} onClose={onClose} />}
                </StoryModalLauncher>
            </MockProviders>
        ),
    },
];
