import React from "react";
import { ReceiveSecretDialog } from "../../components/receive-secret-dialog";
import { MockProviders, StoryModalLauncher } from "../mocks";
import type { IStory } from "../types";

//
// Stories for the ReceiveSecretDialog.
//
export const stories: IStory[] = [
    {
        id: "receive-secret-dialog/open",
        name: "Receive Secret",
        category: "Dialogs",
        render: () => (
            <MockProviders>
                <StoryModalLauncher label="receive secret dialog">
                    {(open, onClose) => <ReceiveSecretDialog open={open} onClose={onClose} />}
                </StoryModalLauncher>
            </MockProviders>
        ),
    },
];
