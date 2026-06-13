import React from "react";
import { ImportPage } from "../../pages/import/import-page";
import { MockProviders, mockImportContext, mockInProgressImportItems } from "../mocks";
import type { IStory } from "../types";

//
// Stories for the Import page.
//
export const stories: IStory[] = [
    {
        id: "import-page/idle",
        name: "Import (idle)",
        category: "Pages",
        render: () => (
            <MockProviders>
                <ImportPage />
            </MockProviders>
        ),
    },
    {
        id: "import-page/in-progress",
        name: "Import (in progress)",
        category: "Pages",
        render: () => (
            <MockProviders importContext={mockImportContext({ status: 'running', importItems: mockInProgressImportItems() })}>
                <ImportPage />
            </MockProviders>
        ),
    },
];
