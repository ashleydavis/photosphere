import React from "react";
import { ResetDeviceDialog } from "../../components/reset-device-dialog";
import { MockProviders, StoryModalLauncher } from "../mocks";
import type { IStory } from "../types";

//
// Stories for the ResetDeviceDialog. Both steps are reachable from the one story: the launcher opens
// it on the first step and its Continue button leads to the final confirmation.
//
export const stories: IStory[] = [
    {
        id: "reset-device-dialog/open",
        name: "Reset Device",
        category: "Dialogs",
        render: () => (
            <MockProviders>
                <StoryModalLauncher label="reset device dialog">
                    {(open, onClose) => <ResetDeviceDialog open={open} onClose={onClose} />}
                </StoryModalLauncher>
            </MockProviders>
        ),
    },
];
