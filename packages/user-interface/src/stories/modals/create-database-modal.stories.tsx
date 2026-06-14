import React from "react";
import { CreateDatabaseModal } from "../../components/create-database-modal";
import { MockProviders, StoryModalLauncher } from "../mocks";
import type { IStory } from "../types";

//
// Stories for the CreateDatabaseModal.
//
export const stories: IStory[] = [
    {
        id: "create-database-modal/open",
        name: "Create Database",
        category: "Modals",
        render: () => (
            <MockProviders>
                <StoryModalLauncher label="create database modal">
                    {(open, onClose) => <CreateDatabaseModal open={open} onClose={onClose} />}
                </StoryModalLauncher>
            </MockProviders>
        ),
    },
];
