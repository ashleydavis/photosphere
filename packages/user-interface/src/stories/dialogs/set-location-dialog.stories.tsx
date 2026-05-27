import React from "react";
import { SetLocationDialog } from "../../components/set-location-dialog";
import { MockProviders, noOp } from "../mocks";
import type { IStory } from "../types";

//
// Stories for the SetLocationDialog.
//
export const stories: IStory[] = [
    {
        id: "set-location-dialog/empty",
        name: "Set Location (empty)",
        category: "Dialogs",
        render: () => (
            <MockProviders>
                <SetLocationDialog
                    open={true}
                    onSetLocation={noOp}
                    onClearLocation={noOp}
                    onClose={noOp}
                    />
            </MockProviders>
        ),
    },
    {
        id: "set-location-dialog/with-existing-location",
        name: "Set Location (with existing)",
        category: "Dialogs",
        render: () => (
            <MockProviders>
                <SetLocationDialog
                    open={true}
                    initialCoordinates={{ lat: -33.8688, lng: 151.2093 }}
                    onSetLocation={noOp}
                    onClearLocation={noOp}
                    onClose={noOp}
                    />
            </MockProviders>
        ),
    },
];
