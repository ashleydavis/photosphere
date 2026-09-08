import React, { ReactNode, useEffect, useState } from "react";
import Typography from "@mui/joy/Typography/Typography";
import { ExpandMore, KeyboardArrowRight } from "@mui/icons-material";
import { useState as useStateStore } from "../context/state-context";

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
    // Optional style applied to the header row.
    //
    style?: React.CSSProperties;

    //
    // The content to show when the section is expanded.
    //
    children: ReactNode | ReactNode[];
}

//
// A sidebar section with a clickable header that collapses/expands its content.
// Whether it is collapsed is remembered in the state store under the given key.
//
export function CollapsibleSection({ configKey, label, style, children }: ICollapsibleSectionProps) {
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
            <div
                className="flex flex-row items-center mt-4 cursor-pointer"
                style={style}
                onClick={toggle}
                >
                <Typography
                    level="body-xs"
                    sx={{ textTransform: 'uppercase', fontWeight: 'lg' }}
                    >
                    {label}
                </Typography>
                <div className="flex-grow" />
                {collapsed
                    ? <KeyboardArrowRight fontSize="small" />
                    : <ExpandMore fontSize="small" />
                }
            </div>

            {!collapsed && children}
        </>
    );
}
