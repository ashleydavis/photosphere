import React from "react";
import { ReplicateDatabaseDialog } from "../../components/replicate-database-dialog";
import { MockProviders, noOp, noOpAsync } from "../mocks";
import type { IStory } from "../types";
import type { IDatabaseEntry } from "../../context/platform-context";

//
// Sample source entry used by the replicate-database dialog story.
//
const sampleEntry: IDatabaseEntry = {
    name: "Family Photos",
    description: "Holiday and family albums",
    path: "/photos/family",
};

//
// Stories for the ReplicateDatabaseDialog.
//
export const stories: IStory[] = [
    {
        id: "replicate-database-dialog/open",
        name: "Replicate Database",
        category: "Dialogs",
        render: () => (
            <MockProviders>
                <ReplicateDatabaseDialog
                    open={true}
                    sourceEntry={sampleEntry}
                    encryptionSecrets={[]}
                    s3Secrets={[]}
                    geocodingSecrets={[]}
                    onSecretCreated={noOpAsync}
                    onClose={noOp}
                    />
            </MockProviders>
        ),
    },
];
