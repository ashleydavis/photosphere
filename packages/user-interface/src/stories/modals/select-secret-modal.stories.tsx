import React from "react";
import { SelectSecretModal } from "../../components/select-secret-modal";
import { MockProviders, mockPlatform, noOp } from "../mocks";
import type { IStory } from "../types";
import type { ISharedSecretEntry } from "../../context/platform-context";

//
// Mock secret list used by the select-secret modal story.
//
const sampleSecrets: ISharedSecretEntry[] = [
    { name: "aws-prod", type: "s3-credentials" },
    { name: "aws-staging", type: "s3-credentials" },
];

//
// Stories for the SelectSecretModal.
//
export const stories: IStory[] = [
    {
        id: "select-secret-modal/open",
        name: "Select Secret",
        category: "Modals",
        render: () => {
            const platform = mockPlatform();
            platform.listSecrets = async () => sampleSecrets;
            return (
                <MockProviders platform={platform}>
                    <SelectSecretModal open={true} secretType="s3-credentials" onClose={noOp} onSelect={noOp} />
                </MockProviders>
            );
        },
    },
];
