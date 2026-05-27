import React from "react";
import { Fps } from "../../components/fps";
import type { IStory } from "../types";

//
// Stories for the Fps component. Purely presentational; no provider wrapper required.
//
export const stories: IStory[] = [
    {
        id: "fps/default",
        name: "FPS",
        category: "Components",
        render: () => <Fps />,
    },
];
