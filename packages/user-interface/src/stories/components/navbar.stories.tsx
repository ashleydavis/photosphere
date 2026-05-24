import React from "react";
import { Navbar } from "../../components/navbar";
import { MockProviders, noOp } from "../mocks";
import type { IStory } from "../types";

//
// Stories for the Navbar.
//
export const stories: IStory[] = [
    {
        id: "navbar/default",
        name: "Navbar",
        category: "Components",
        render: () => (
            <MockProviders>
                <Navbar
                    sidebarOpen={false}
                    setSidebarOpen={noOp}
                    setRightSidebarOpen={noOp}
                    onOpenConfiguration={noOp}
                    />
            </MockProviders>
        ),
    },
];
