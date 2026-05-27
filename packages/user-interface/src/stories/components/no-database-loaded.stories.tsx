import React from "react";
import { NoDatabaseLoaded } from "../../components/no-database-loaded";
import { MockProviders } from "../mocks";
import type { IStory } from "../types";

//
// Stories for the NoDatabaseLoaded component.
//
export const stories: IStory[] = [
    {
        id: "no-database-loaded/default",
        name: "No Database Loaded",
        category: "Components",
        render: () => (
            <MockProviders>
                <NoDatabaseLoaded />
            </MockProviders>
        ),
    },
];
