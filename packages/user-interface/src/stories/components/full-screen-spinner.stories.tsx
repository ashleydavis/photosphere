import React from "react";
import { FullscreenSpinner } from "../../components/full-screen-spinnner";
import { StoryModalLauncher } from "../mocks";
import type { IStory } from "../types";

//
// Stories for the FullscreenSpinner component. The spinner is shown on demand
// over the launcher's solid full-screen backdrop; clicking anywhere dismisses
// it and restores the story browser.
//
export const stories: IStory[] = [
    {
        id: "full-screen-spinner/visible",
        name: "Full-screen Spinner",
        category: "Components",
        render: () => (
            <StoryModalLauncher label="full-screen spinner">
                {(open, onClose) => (
                    <div onClick={onClose} style={{ position: "absolute", inset: 0 }}>
                        <FullscreenSpinner />
                    </div>
                )}
            </StoryModalLauncher>
        ),
    },
];
