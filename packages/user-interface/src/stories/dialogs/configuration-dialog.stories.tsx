import React from "react";
import { ConfigurationDialog } from "../../components/configuration-dialog";
import { MockProviders, noOp } from "../mocks";
import type { IStory } from "../types";

//
// Stories for the ConfigurationDialog.
//
export const stories: IStory[] = [
    {
        id: "configuration-dialog/open",
        name: "Configuration",
        category: "Dialogs",
        render: () => (
            <MockProviders>
                <ConfigurationDialog open={true} onClose={noOp} />
            </MockProviders>
        ),
    },
];
