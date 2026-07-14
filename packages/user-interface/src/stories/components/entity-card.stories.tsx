import React from "react";
import Storage from "@mui/icons-material/Storage";
import Key from "@mui/icons-material/Key";
import Visibility from "@mui/icons-material/Visibility";
import IosShare from "@mui/icons-material/IosShare";
import Edit from "@mui/icons-material/Edit";
import Delete from "@mui/icons-material/Delete";
import { EntityCard } from "../../components/entity-card";
import { MockProviders } from "../mocks";
import type { IStory } from "../types";

//
// Stories for the EntityCard: the card that replaces a table row on a phone.
//
export const stories: IStory[] = [
    {
        id: "entity-card/database",
        name: "Entity Card (database)",
        category: "Components",
        render: () => (
            <MockProviders>
                <EntityCard
                    title="Family Photos"
                    subtitle="Holiday and family albums"
                    detail="/photos/family"
                    icon={<Storage />}
                    onClick={() => {}}
                    actions={[
                        { label: "View details", icon: <Visibility fontSize="small" />, onClick: () => {} },
                        { label: "Share", icon: <IosShare fontSize="small" />, onClick: () => {} },
                        { label: "Edit", icon: <Edit fontSize="small" />, onClick: () => {} },
                        { label: "Remove", icon: <Delete fontSize="small" />, danger: true, onClick: () => {} },
                    ]}
                    />
            </MockProviders>
        ),
    },
    {
        id: "entity-card/secret",
        name: "Entity Card (secret)",
        category: "Components",
        render: () => (
            <MockProviders>
                <EntityCard
                    title="aws-prod"
                    subtitle="s3-credentials"
                    icon={<Key />}
                    onClick={() => {}}
                    actions={[
                        { label: "Share", icon: <IosShare fontSize="small" />, onClick: () => {} },
                        { label: "Edit", icon: <Edit fontSize="small" />, onClick: () => {} },
                        { label: "Delete", icon: <Delete fontSize="small" />, danger: true, onClick: () => {} },
                    ]}
                    />
            </MockProviders>
        ),
    },
    {
        id: "entity-card/long-values",
        name: "Entity Card (long values)",
        category: "Components",
        render: () => (
            <MockProviders>
                <EntityCard
                    title="A database with a very long name that cannot possibly fit on one line"
                    subtitle="A description that is also far too long to fit across a phone screen in one go"
                    detail="s3:some-very-long-bucket-name:/deeply/nested/path/to/the/database/root"
                    icon={<Storage />}
                    onClick={() => {}}
                    actions={[
                        { label: "View details", icon: <Visibility fontSize="small" />, onClick: () => {} },
                        { label: "Remove", icon: <Delete fontSize="small" />, danger: true, onClick: () => {} },
                    ]}
                    />
            </MockProviders>
        ),
    },
];
