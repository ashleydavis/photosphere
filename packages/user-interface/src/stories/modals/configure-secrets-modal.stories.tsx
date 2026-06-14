import React from "react";
import { ConfigureSecretsModal } from "../../components/configure-secrets-modal";
import { MockProviders, StoryModalLauncher, noOp } from "../mocks";
import type { IStory } from "../types";

//
// Stories for the ConfigureSecretsModal.
//
export const stories: IStory[] = [
    {
        id: "configure-secrets-modal/open",
        name: "Configure Secrets",
        category: "Modals",
        render: () => (
            <MockProviders>
                <StoryModalLauncher label="configure secrets modal">
                    {(open, onClose) => (
                        <ConfigureSecretsModal
                            open={open}
                            initialValue={{ s3Key: undefined, encryptionKey: undefined, geocodingKey: undefined }}
                            s3Secrets={[]}
                            encryptionSecrets={[]}
                            geocodingSecrets={[]}
                            onSave={noOp}
                            onClose={onClose}
                            />
                    )}
                </StoryModalLauncher>
            </MockProviders>
        ),
    },
];
