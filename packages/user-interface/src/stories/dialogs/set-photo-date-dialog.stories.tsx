import React from "react";
import { SetPhotoDateDialog } from "../../components/set-photo-date-dialog";
import { MockProviders, noOp, noOpAsync } from "../mocks";
import type { IStory } from "../types";

//
// Stories for the SetPhotoDateDialog.
//
export const stories: IStory[] = [
    {
        id: "set-photo-date-dialog/empty",
        name: "Set Photo Date (empty)",
        category: "Dialogs",
        render: () => (
            <MockProviders>
                <SetPhotoDateDialog open={true} onClose={noOp} onSetDate={noOpAsync} />
            </MockProviders>
        ),
    },
    {
        id: "set-photo-date-dialog/with-existing-date",
        name: "Set Photo Date (with existing)",
        category: "Dialogs",
        render: () => (
            <MockProviders>
                <SetPhotoDateDialog
                    open={true}
                    onClose={noOp}
                    onSetDate={noOpAsync}
                    currentDate="2024-06-15T10:30:00.000Z"
                    />
            </MockProviders>
        ),
    },
];
