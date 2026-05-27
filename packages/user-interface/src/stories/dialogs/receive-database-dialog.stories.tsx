import React from "react";
import { ReceiveDatabaseDialog } from "../../components/receive-database-dialog";
import { MockProviders, noOp } from "../mocks";
import type { IStory } from "../types";

//
// Stories for the ReceiveDatabaseDialog.
//
export const stories: IStory[] = [
    {
        id: "receive-database-dialog/open",
        name: "Receive Database",
        category: "Dialogs",
        render: () => (
            <MockProviders>
                <ReceiveDatabaseDialog open={true} onClose={noOp} />
            </MockProviders>
        ),
    },
];
