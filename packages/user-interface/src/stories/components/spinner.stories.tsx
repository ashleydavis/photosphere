import React from "react";
import { Spinner } from "../../components/spinner";
import type { IStory } from "../types";

//
// Stories for the Spinner. Purely presentational; no provider wrapper required.
//
export const stories: IStory[] = [
    {
        id: "spinner/visible",
        name: "Spinner (visible)",
        category: "Components",
        render: () => <Spinner show={true} />,
    },
    {
        id: "spinner/hidden",
        name: "Spinner (hidden)",
        category: "Components",
        render: () => <Spinner show={false} />,
    },
];
