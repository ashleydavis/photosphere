import React from "react";
import { S3BrowserModal } from "../../components/s3-browser-modal";
import { MockProviders, StoryModalLauncher, mockPlatform, noOp } from "../mocks";
import type { IStory } from "../types";

//
// Stories for the S3BrowserModal.
//
export const stories: IStory[] = [
    {
        id: "s3-browser-modal/open",
        name: "S3 Browser",
        category: "Modals",
        render: () => {
            const platform = mockPlatform();
            platform.listS3Dirs = async () => ["albums", "raw", "thumbnails"];
            return (
                <MockProviders platform={platform}>
                    <StoryModalLauncher label="S3 browser modal">
                        {(open, onClose) => <S3BrowserModal open={open} s3Key="aws-prod" onClose={onClose} onSelect={noOp} />}
                    </StoryModalLauncher>
                </MockProviders>
            );
        },
    },
];
