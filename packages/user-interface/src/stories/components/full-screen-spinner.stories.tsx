import React from "react";
import { FullscreenSpinner } from "../../components/full-screen-spinnner";
import type { IStory } from "../types";

//
// Stories for the FullscreenSpinner component.
//
export const stories: IStory[] = [
    {
        id: "full-screen-spinner/visible",
        name: "Full-screen Spinner",
        category: "Components",
        render: () => <FullscreenSpinner />,
    },
];
