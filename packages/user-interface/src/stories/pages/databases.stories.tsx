import React from "react";
import { DatabasesPage } from "../../pages/databases/databases-page";
import { MockProviders, mockPlatform } from "../mocks";
import type { IStory } from "../types";
import type { IDatabaseEntry } from "../../context/platform-context";

//
// A mock list of three database entries used by the with-databases variant.
//
const sampleDatabases: IDatabaseEntry[] = [
    { name: "Family Photos", description: "Holiday and family albums", path: "/photos/family" },
    { name: "Work", description: "Project screenshots", path: "/photos/work" },
    { name: "Archive", description: "Older content", path: "s3:archive:/photos" },
];

//
// Stories for the Databases page.
//
export const stories: IStory[] = [
    {
        id: "databases-page/empty",
        name: "Databases (empty)",
        category: "Pages",
        render: () => {
            const platform = mockPlatform();
            return (
                <MockProviders platform={platform}>
                    <DatabasesPage />
                </MockProviders>
            );
        },
    },
    {
        id: "databases-page/with-databases",
        name: "Databases (with entries)",
        category: "Pages",
        render: () => {
            const platform = mockPlatform();
            platform.getDatabases = async () => sampleDatabases;
            platform.getRecentDatabases = async () => sampleDatabases;
            return (
                <MockProviders platform={platform}>
                    <DatabasesPage />
                </MockProviders>
            );
        },
    },
];
