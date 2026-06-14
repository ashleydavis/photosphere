import React from "react";
import { SelectSecretModal } from "../../components/select-secret-modal";
import { MockProviders, StoryModalLauncher, mockPlatform, noOp } from "../mocks";
import type { IStory } from "../types";
import type { ISharedSecretEntry } from "../../context/platform-context";

//
// Mock secret list used by the "with secrets" variant.
//
const sampleSecrets: ISharedSecretEntry[] = [
    { name: "aws-prod", type: "s3-credentials" },
    { name: "aws-staging", type: "s3-credentials" },
];

//
// Stories for the SelectSecretModal: one populated with secrets and one empty.
//
export const stories: IStory[] = [
    {
        id: "select-secret-modal/with-secrets",
        name: "Select Secret (with secrets)",
        category: "Modals",
        render: () => {
            const platform = mockPlatform();
            platform.listSecrets = async () => sampleSecrets;
            return (
                <MockProviders platform={platform}>
                    <StoryModalLauncher label="select secret modal (with secrets)">
                        {(open, onClose) => <SelectSecretModal open={open} secretType="s3-credentials" onClose={onClose} onSelect={noOp} />}
                    </StoryModalLauncher>
                </MockProviders>
            );
        },
    },
    {
        id: "select-secret-modal/empty",
        name: "Select Secret (empty)",
        category: "Modals",
        render: () => (
            <MockProviders>
                <StoryModalLauncher label="select secret modal (empty)">
                    {(open, onClose) => <SelectSecretModal open={open} secretType="s3-credentials" onClose={onClose} onSelect={noOp} />}
                </StoryModalLauncher>
            </MockProviders>
        ),
    },
];
