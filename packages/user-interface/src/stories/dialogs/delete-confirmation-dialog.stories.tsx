import React from "react";
import { DeleteConfirmationDialog } from "../../components/delete-confirmation-dialog";
import { MockProviders, StoryModalLauncher } from "../mocks";
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
                <StoryModalLauncher label="delete confirmation (1 item)">
                    {(open, onClose) => open
                        ? <DeleteConfirmationDialog open={open} numItems={1} onCancel={onClose} onDelete={async () => onClose()} />
                        : null
                    }
                </StoryModalLauncher>
            </MockProviders>
        ),
    },
    {
        id: "delete-confirmation-dialog/many-items",
        name: "Delete Confirmation (many items)",
        category: "Dialogs",
        render: () => (
            <MockProviders>
                <StoryModalLauncher label="delete confirmation (many items)">
                    {(open, onClose) => open
                        ? <DeleteConfirmationDialog open={open} numItems={42} onCancel={onClose} onDelete={async () => onClose()} />
                        : null
                    }
                </StoryModalLauncher>
            </MockProviders>
        ),
    },
];
