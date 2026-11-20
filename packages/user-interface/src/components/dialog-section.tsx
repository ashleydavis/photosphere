import React, { type ReactNode } from "react";
import Box from "@mui/material/Box";

//
// Props for DialogSection.
//
export interface IDialogSectionProps {
    //
    // The section's heading, or an empty string for a section with no heading.
    //
    heading: string;

    //
    // The section's rows. Each child is one row, divided from the row above it.
    //
    children: ReactNode;
}

//
// Draws a group of a dialog's settings as a card of rows under a muted heading, in the settings
// tokens, so the configuration dialog's sections look like the style guide's settings sections.
//
export function DialogSection({ heading, children }: IDialogSectionProps): React.ReactElement {
    return (
        <Box
            component="section"
            sx={{
                display: "flex",
                flexDirection: "column",
                gap: "var(--space-1)",
            }}
            >
            {heading !== ""
                && <Box
                    sx={{
                        padding: "0px var(--space-3)",
                        color: "var(--color-text-muted)",
                        fontSize: "var(--text-sm)",
                        fontWeight: "var(--weight-bold)",
                    }}
                    >
                    {heading}
                </Box>
            }
            <Box
                sx={{
                    display: "flex",
                    flexDirection: "column",
                    overflow: "hidden",
                    backgroundColor: "var(--color-settings-section-bg)",
                    border: "1px solid var(--color-settings-section-border)",
                    borderRadius: "var(--radius-settings-section)",
                    "& > * + *": {
                        borderTop: "var(--settings-row-divider-width) solid var(--color-border)",
                    },
                }}
                >
                {children}
            </Box>
        </Box>
    );
}

//
// Props for SectionRow.
//
export interface ISectionRowProps {
    //
    // What the row sets, at its left.
    //
    label: ReactNode;

    //
    // A muted line under the label, or undefined for none.
    //
    hint: ReactNode | undefined;

    //
    // The row's control, at its right.
    //
    control: ReactNode;
}

//
// Draws one row of a DialogSection: a label, with its hint under it, and a control at the right.
//
export function SectionRow({ label, hint, control }: ISectionRowProps): React.ReactElement {
    return (
        <Box
            sx={{
                display: "flex",
                alignItems: "center",
                justifyContent: "space-between",
                gap: "var(--space-3)",
                minHeight: "calc(var(--space-8) + var(--space-6))",
                padding: "var(--space-2) var(--space-3)",
            }}
            >
            <Box
                sx={{
                    display: "flex",
                    flexDirection: "column",
                    minWidth: 0,
                }}
                >
                <span>{label}</span>
                {hint
                    && <Box
                        component="span"
                        sx={{
                            color: "var(--color-text-muted)",
                            fontSize: "var(--text-sm)",
                        }}
                        >
                        {hint}
                    </Box>
                }
            </Box>
            {control}
        </Box>
    );
}
