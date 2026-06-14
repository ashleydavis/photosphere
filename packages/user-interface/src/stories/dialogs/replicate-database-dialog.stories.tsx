import React from "react";
import { ReplicateDatabaseDialog } from "../../components/replicate-database-dialog";
import { MockProviders, StoryModalLauncher } from "../mocks";
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
                <StoryModalLauncher label="replicate database dialog">
                    {(open, onClose) => (
                        <ReplicateDatabaseDialog
                            open={open}
                            sourceEntry={sampleEntry}
                            encryptionSecrets={[]}
                            s3Secrets={[]}
                            geocodingSecrets={[]}
                            onClose={onClose}
                            />
                    )}
                </StoryModalLauncher>
            </MockProviders>
        ),
    },
];
