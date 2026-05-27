import React from "react";
import { DeleteConfirmationDialog } from "../../components/delete-confirmation-dialog";
import { MockProviders, noOp, noOpAsync } from "../mocks";
import type { IStory } from "../types";

//
// Stories for the DeleteConfirmationDialog.
//
export const stories: IStory[] = [
    {
        id: "delete-confirmation-dialog/single-item",
        name: "Delete Confirmation (1 item)",
        category: "Dialogs",
        render: () => (
            <MockProviders>
                <DeleteConfirmationDialog open={true} numItems={1} onCancel={noOp} onDelete={noOpAsync} />
            </MockProviders>
        ),
    },
    {
        id: "delete-confirmation-dialog/many-items",
        name: "Delete Confirmation (many items)",
        category: "Dialogs",
        render: () => (
            <MockProviders>
                <DeleteConfirmationDialog open={true} numItems={42} onCancel={noOp} onDelete={noOpAsync} />
            </MockProviders>
        ),
    },
];
