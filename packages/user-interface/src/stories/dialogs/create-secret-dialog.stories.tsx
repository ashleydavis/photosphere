import React from "react";
import { CreateSecretDialog } from "../../components/create-secret-dialog";
import { MockProviders, StoryModalLauncher, noOp } from "../mocks";
import type { IStory } from "../types";

//
// Stories for the CreateSecretDialog.
//
export const stories: IStory[] = [
    {
        id: "create-secret-dialog/open",
        name: "Create Secret",
        category: "Dialogs",
        render: () => (
            <MockProviders>
                <StoryModalLauncher label="create secret dialog">
                    {(open, onClose) => (
                        <CreateSecretDialog
                            open={open}
                            secretType="s3-credentials"
                            defaultName="my-secret"
                            onClose={onClose}
                            onSave={noOp}
                            />
                    )}
                </StoryModalLauncher>
            </MockProviders>
        ),
    },
];
