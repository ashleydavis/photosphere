import React from "react";
import { ConfigurationDialog } from "../../components/configuration-dialog";
import { MockProviders, StoryModalLauncher } from "../mocks";
import type { IStory } from "../types";

//
// Stories for the ConfigurationDialog.
//
export const stories: IStory[] = [
    {
        id: "configuration-dialog/open",
        name: "Configuration",
        category: "Dialogs",
        render: () => (
            <MockProviders>
                <StoryModalLauncher label="configuration dialog">
                    {(open, onClose) => <ConfigurationDialog open={open} onClose={onClose} />}
                </StoryModalLauncher>
            </MockProviders>
        ),
    },
];
