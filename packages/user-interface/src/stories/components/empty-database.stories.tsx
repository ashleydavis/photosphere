import React from "react";
import { EmptyDatabase } from "../../components/empty-database";
import { MockProviders } from "../mocks";
import type { IStory } from "../types";

//
// Stories for the EmptyDatabase component.
//
export const stories: IStory[] = [
    {
        id: "empty-database/default",
        name: "Empty Database",
        category: "Components",
        render: () => (
            <MockProviders>
                <EmptyDatabase />
            </MockProviders>
        ),
    },
];
