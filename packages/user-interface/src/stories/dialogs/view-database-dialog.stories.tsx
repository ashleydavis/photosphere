import React from "react";
import { ViewDatabaseDialog } from "../../components/view-database-dialog";
import { MockProviders, noOp } from "../mocks";
import type { IStory } from "../types";
import type { IDatabaseEntry } from "../../context/platform-context";

//
// Sample entry used by the view-database dialog story.
//
const sampleEntry: IDatabaseEntry = {
    name: "Family Photos",
    description: "Holiday and family albums",
    path: "/photos/family",
    origin: "primary",
};

//
// Stories for the ViewDatabaseDialog.
//
export const stories: IStory[] = [
    {
        id: "view-database-dialog/open",
        name: "View Database",
        category: "Dialogs",
        render: () => (
            <MockProviders>
                <ViewDatabaseDialog
                    open={true}
                    entry={sampleEntry}
                    allSecrets={[]}
                    onClose={noOp}
                    getSecretValue={async () => undefined}
                    />
            </MockProviders>
        ),
    },
];
