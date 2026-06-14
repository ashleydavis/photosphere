import React from "react";
import { ViewSecretDialog } from "../../components/view-secret-dialog";
import { MockProviders, StoryModalLauncher } from "../mocks";
import type { IStory } from "../types";
import type { ISharedSecretEntry } from "../../context/platform-context";

//
// S3 credentials secret and its revealed value.
//
const s3Secret: ISharedSecretEntry = { name: "aws-prod", type: "s3-credentials" };
const s3Value = JSON.stringify({
    endpoint: "https://s3.ap-southeast-2.amazonaws.com",
    region: "ap-southeast-2",
    accessKeyId: "AKIAEXAMPLE1234567890",
    secretAccessKey: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
});

//
// Encryption key secret and its revealed value.
//
const encryptionSecret: ISharedSecretEntry = { name: "vault-key", type: "encryption-key" };
const encryptionValue = JSON.stringify({
    privateKeyPem: "-----BEGIN PRIVATE KEY-----\nMIIBVAIBADANBgkqhkiG9w0BAQEFAASCAT4...\n-----END PRIVATE KEY-----",
});

//
// API key secret and its revealed value.
//
const apiKeySecret: ISharedSecretEntry = { name: "geocoding", type: "api-key" };
const apiKeyValue = JSON.stringify({ apiKey: "geo_live_0123456789abcdef" });

//
// Stories for the ViewSecretDialog: one per secret type, since each type renders
// a different set of revealed fields.
//
export const stories: IStory[] = [
    {
        id: "view-secret-dialog/s3-credentials",
        name: "View Secret (S3 credentials)",
        category: "Dialogs",
        render: () => (
            <MockProviders>
                <StoryModalLauncher label="view secret dialog (S3 credentials)">
                    {(open, onClose) => (
                        <ViewSecretDialog
                            open={open}
                            secret={s3Secret}
                            onClose={onClose}
                            getSecretValue={async () => s3Value}
                            />
                    )}
                </StoryModalLauncher>
            </MockProviders>
        ),
    },
    {
        id: "view-secret-dialog/encryption-key",
        name: "View Secret (encryption key)",
        category: "Dialogs",
        render: () => (
            <MockProviders>
                <StoryModalLauncher label="view secret dialog (encryption key)">
                    {(open, onClose) => (
                        <ViewSecretDialog
                            open={open}
                            secret={encryptionSecret}
                            onClose={onClose}
                            getSecretValue={async () => encryptionValue}
                            />
                    )}
                </StoryModalLauncher>
            </MockProviders>
        ),
    },
    {
        id: "view-secret-dialog/api-key",
        name: "View Secret (API key)",
        category: "Dialogs",
        render: () => (
            <MockProviders>
                <StoryModalLauncher label="view secret dialog (API key)">
                    {(open, onClose) => (
                        <ViewSecretDialog
                            open={open}
                            secret={apiKeySecret}
                            onClose={onClose}
                            getSecretValue={async () => apiKeyValue}
                            />
                    )}
                </StoryModalLauncher>
            </MockProviders>
        ),
    },
];
