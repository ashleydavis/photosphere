import React from "react";
import Add from "@mui/icons-material/Add";
import NoteAdd from "@mui/icons-material/NoteAdd";
import Download from "@mui/icons-material/Download";
import { MobilePageHeader } from "../../components/mobile-page-header";
import { MockProviders } from "../mocks";
import type { IStory } from "../types";

//
// Stories for the MobilePageHeader: the header used by the management pages, which folds its
// secondary actions into an overflow menu on a phone.
//
export const stories: IStory[] = [
    {
        id: "mobile-page-header/databases",
        name: "Page Header (databases)",
        category: "Components",
        render: () => (
            <MockProviders>
                <MobilePageHeader
                    title="Manage Databases"
                    subtitle="3 databases"
                    refreshing={false}
                    onRefresh={() => {}}
                    primaryAction={{ label: "New database", icon: <Add />, onClick: () => {} }}
                    secondaryActions={[
                        { label: "Add database", icon: <NoteAdd fontSize="small" />, onClick: () => {} },
                        { label: "Receive database", icon: <Download fontSize="small" />, onClick: () => {} },
                    ]}
                    />
            </MockProviders>
        ),
    },
    {
        id: "mobile-page-header/refreshing",
        name: "Page Header (refreshing)",
        category: "Components",
        render: () => (
            <MockProviders>
                <MobilePageHeader
                    title="Manage Secrets"
                    subtitle="1 secret"
                    refreshing={true}
                    onRefresh={() => {}}
                    primaryAction={{ label: "Add secret", icon: <Add />, onClick: () => {} }}
                    secondaryActions={[
                        { label: "Receive secret", icon: <Download fontSize="small" />, onClick: () => {} },
                    ]}
                    />
            </MockProviders>
        ),
    },
];
