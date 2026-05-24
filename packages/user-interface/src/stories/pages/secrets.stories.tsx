import React from "react";
import { SecretsPage } from "../../pages/secrets/secrets-page";
import { MockProviders, mockPlatform } from "../mocks";
import type { IStory } from "../types";
import type { ISharedSecretEntry } from "../../context/platform-context";

//
// A mock list of three secrets used by the with-secrets variant.
//
const sampleSecrets: ISharedSecretEntry[] = [
    { name: "aws-prod", type: "s3-credentials" },
    { name: "vault-key", type: "encryption-key" },
    { name: "geocoder", type: "api-key" },
];

//
// Stories for the Secrets page.
//
export const stories: IStory[] = [
    {
        id: "secrets-page/empty",
        name: "Secrets (empty)",
        category: "Pages",
        render: () => (
            <MockProviders platform={mockPlatform()}>
                <SecretsPage />
            </MockProviders>
        ),
    },
    {
        id: "secrets-page/with-secrets",
        name: "Secrets (with entries)",
        category: "Pages",
        render: () => {
            const platform = mockPlatform();
            platform.listSecrets = async () => sampleSecrets;
            return (
                <MockProviders platform={platform}>
                    <SecretsPage />
                </MockProviders>
            );
        },
    },
];
