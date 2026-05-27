import React from "react";
import { ViewSecretDialog } from "../../components/view-secret-dialog";
import { MockProviders, noOp } from "../mocks";
import type { IStory } from "../types";
import type { ISharedSecretEntry } from "../../context/platform-context";

//
// Sample entry used by the view-secret dialog story.
//
const sampleSecret: ISharedSecretEntry = { name: "aws-prod", type: "s3-credentials" };

//
// Stories for the ViewSecretDialog.
//
export const stories: IStory[] = [
    {
        id: "view-secret-dialog/open",
        name: "View Secret",
        category: "Dialogs",
        render: () => (
            <MockProviders>
                <ViewSecretDialog
                    open={true}
                    secret={sampleSecret}
                    onClose={noOp}
                    getSecretValue={async () => "***hidden***"}
                    />
            </MockProviders>
        ),
    },
];
