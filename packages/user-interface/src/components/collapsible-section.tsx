import React, { ReactNode, useEffect, useState } from "react";
import Typography from "@mui/joy/Typography/Typography";
import { ExpandMore, KeyboardArrowRight } from "@mui/icons-material";
import { useConfig } from "../context/config-context";

export interface ICollapsibleSectionProps {
    //
    // The config key used to persist collapsed state.
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
// A sidebar section with a clickable header that collapses/expands its content.
// Collapsed state is persisted to config under the given key.
//
export function CollapsibleSection({ configKey, label, children }: ICollapsibleSectionProps) {
    const config = useConfig();

    //
    // Whether the section is currently collapsed.
    //
    const [collapsed, setCollapsed] = useState<boolean>(false);

    //
    // Load persisted collapsed state on mount.
    //
    useEffect(() => {
        config.get<boolean>(configKey).then(value => {
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
        await config.set<boolean>(configKey, next);
    }

    return (
        <>
            <div
                className="flex flex-row items-center mt-4 cursor-pointer"
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
