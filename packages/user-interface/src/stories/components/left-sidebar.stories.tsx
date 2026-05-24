import React from "react";
import { LeftSidebar } from "../../components/left-sidebar";
import { MockProviders, noOp } from "../mocks";
import type { IStory } from "../types";

//
// Stories for the LeftSidebar.
//
export const stories: IStory[] = [
    {
        id: "left-sidebar/open",
        name: "Left Sidebar",
        category: "Components",
        render: () => (
            <MockProviders>
                <LeftSidebar
                    sidebarOpen={true}
                    setSidebarOpen={noOp}
                    onOpenConfiguration={noOp}
                    onNewDatabase={noOp}
                    onOpenDatabase={noOp}
                    />
            </MockProviders>
        ),
    },
];
