import React from "react";
import { EditDatabaseModal } from "../../components/edit-database-modal";
import { MockProviders, noOp, noOpAsync } from "../mocks";
import type { IStory } from "../types";
import type { IDatabaseEntry } from "../../context/platform-context";

//
// Sample database entry used to populate the edit dialog.
//
const sampleEntry: IDatabaseEntry = {
    name: "Family Photos",
    description: "Holiday and family albums",
    path: "/photos/family",
};

//
// Stories for the EditDatabaseModal.
//
export const stories: IStory[] = [
    {
        id: "edit-database-modal/open",
        name: "Edit Database",
        category: "Modals",
        render: () => (
            <MockProviders>
                <EditDatabaseModal
                    open={true}
                    entry={sampleEntry}
                    databases={[sampleEntry]}
                    s3Secrets={[]}
                    encryptionSecrets={[]}
                    geocodingSecrets={[]}
                    onClose={noOp}
                    onSecretCreated={noOpAsync}
                    />
            </MockProviders>
        ),
    },
];
