import React from "react";
import { ReceiveSecretDialog } from "../../components/receive-secret-dialog";
import { MockProviders, noOp } from "../mocks";
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
                <ReceiveSecretDialog open={true} onClose={noOp} />
            </MockProviders>
        ),
    },
];
