import React, { ReactNode, useEffect, useState } from "react";
import ListItemButton from "@mui/material/ListItemButton";
import { ExpandMore, KeyboardArrowRight } from "@mui/icons-material";
import { useStateStore } from "../context/state-store-context";

export interface ICollapsibleSectionProps {
    //
    // The state key the collapsed/expanded choice is remembered under.
    //
    configKey: string;

    //
    // The label shown in the section header.
    //
    label: string;

    //
    // The content to show when the section is expanded.
    //
    children: ReactNode | ReactNode[];
}

//
// The look of a sidebar section's heading, from the sidebar heading tokens: muted, small and bold
// over its group of rows. It keeps a row's hover colour, since picking it folds the group away.
//
const sectionHeadingSx = {
    minHeight: "var(--button-height-md)",
    color: "var(--color-sidebar-heading-text)",
    backgroundColor: "var(--color-sidebar-heading-bg)",
    fontSize: "var(--sidebar-heading-size)",
    fontWeight: "var(--weight-bold)",
    "&:hover": {
        backgroundColor: "var(--color-hover)",
    },
    "& .MuiSvgIcon-root": {
        fontSize: "var(--icon-lg)",
    },
};

//
// A sidebar section with a clickable header that collapses/expands its content.
// Whether it is collapsed is remembered in the state store under the given key.
//
export function CollapsibleSection({ configKey, label, children }: ICollapsibleSectionProps) {
    const state = useStateStore();

    //
    // Whether the section is currently collapsed.
    //
    const [collapsed, setCollapsed] = useState<boolean>(false);

    //
    // Load persisted collapsed state on mount.
    //
    useEffect(() => {
        state.get<boolean>(configKey).then(value => {
            if (value !== undefined) {
                setCollapsed(value);
            }
        });
    }, []);

    //
    // Toggles collapsed state and persists the change.
    //
    async function toggle() {
        const next = !collapsed;
        setCollapsed(next);
        await state.set<boolean>(configKey, next);
    }

    return (
        <>
            <ListItemButton
                aria-expanded={!collapsed}
                onClick={toggle}
                sx={sectionHeadingSx}
                >
                <span className="flex-1">{label}</span>
                {collapsed
                    ? <KeyboardArrowRight />
                    : <ExpandMore />
                }
            </ListItemButton>

            {!collapsed && children}
        </>
    );
}
