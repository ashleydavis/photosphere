import React from "react";
import { ShareSecretDialog } from "../../components/share-secret-dialog";
import { MockProviders, noOp } from "../mocks";
import type { IStory } from "../types";
import type { ISharedSecretEntry } from "../../context/platform-context";

//
// Sample entry used by the share-secret dialog story.
//
const sampleEntry: ISharedSecretEntry = { name: "aws-prod", type: "s3-credentials" };

//
// Stories for the ShareSecretDialog.
//
export const stories: IStory[] = [
    {
        id: "share-secret-dialog/open",
        name: "Share Secret",
        category: "Dialogs",
        render: () => (
            <MockProviders>
                <ShareSecretDialog open={true} entry={sampleEntry} onClose={noOp} />
            </MockProviders>
        ),
    },
];
