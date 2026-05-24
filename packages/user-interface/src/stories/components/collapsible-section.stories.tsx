import React from "react";
import { CollapsibleSection } from "../../components/collapsible-section";
import { MockProviders } from "../mocks";
import type { IStory } from "../types";

//
// Stories for the CollapsibleSection.
//
export const stories: IStory[] = [
    {
        id: "collapsible-section/collapsed",
        name: "Collapsible Section (collapsed)",
        category: "Components",
        render: () => (
            <MockProviders>
                <CollapsibleSection configKey="story-collapsed" label="Details">
                    <p>Hidden content</p>
                </CollapsibleSection>
            </MockProviders>
        ),
    },
    {
        id: "collapsible-section/expanded",
        name: "Collapsible Section (expanded)",
        category: "Components",
        render: () => (
            <MockProviders>
                <CollapsibleSection configKey="story-expanded" label="Details">
                    <p>Visible content</p>
                </CollapsibleSection>
            </MockProviders>
        ),
    },
];
