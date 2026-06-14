import React from "react";
import { SetLocationDialog } from "../../components/set-location-dialog";
import { MockProviders, StoryModalLauncher, noOp } from "../mocks";
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
                <StoryModalLauncher label="set location dialog (empty)">
                    {(open, onClose) => open
                        ? (
                            <SetLocationDialog
                                open={open}
                                onSetLocation={noOp}
                                onClearLocation={noOp}
                                onClose={onClose}
                                />
                        )
                        : null
                    }
                </StoryModalLauncher>
            </MockProviders>
        ),
    },
    {
        id: "set-location-dialog/with-existing-location",
        name: "Set Location (with existing)",
        category: "Dialogs",
        render: () => (
            <MockProviders>
                <StoryModalLauncher label="set location dialog (with existing)">
                    {(open, onClose) => open
                        ? (
                            <SetLocationDialog
                                open={open}
                                initialCoordinates={{ lat: -33.8688, lng: 151.2093 }}
                                onSetLocation={noOp}
                                onClearLocation={noOp}
                                onClose={onClose}
                                />
                        )
                        : null
                    }
                </StoryModalLauncher>
            </MockProviders>
        ),
    },
];
