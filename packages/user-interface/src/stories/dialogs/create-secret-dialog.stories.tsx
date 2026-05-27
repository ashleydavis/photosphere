import React from "react";
import { CreateSecretDialog } from "../../components/create-secret-dialog";
import { MockProviders, noOp } from "../mocks";
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
                <CreateSecretDialog
                    open={true}
                    secretType="s3-credentials"
                    defaultName="my-secret"
                    onClose={noOp}
                    onSave={noOp}
                    />
            </MockProviders>
        ),
    },
];
