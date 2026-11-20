import React, { type ReactNode } from "react";
import Box from "@mui/material/Box";

//
// Props for DialogIconBadge.
//
export interface IDialogIconBadgeProps {
    //
    // The icon drawn in the badge: an MUI icon or a Font Awesome `<i>` element.
    //
    icon: ReactNode;

    //
    // True for a dialog that asks about something dangerous, such as a delete, so the badge is drawn
    // in the danger colour and the question reads as dangerous before it is read.
    //
    danger: boolean;
}

//
// Draws the round badge that starts a dialog's title row, so each dialog is recognisable by its icon
// before its title is read. Place it inside the DialogTitle, before the title's text. It sits
// inline, so the title's own layout does not have to change.
//
export function DialogIconBadge({ icon, danger }: IDialogIconBadgeProps): React.ReactElement {
    return (
        <Box
            component="span"
            aria-hidden={true}
            sx={{
                display: "inline-flex",
                alignItems: "center",
                justifyContent: "center",
                verticalAlign: "middle",
                flex: "none",
                width: "var(--button-height-md)",
                height: "var(--button-height-md)",
                marginRight: "var(--space-3)",
                borderRadius: "var(--radius-full)",
                fontSize: "var(--icon-md)",
                color: danger ? "var(--color-danger)" : "var(--dialog-icon-color)",
                backgroundColor: danger ? "color-mix(in srgb, var(--color-danger) 14%, transparent)" : "var(--dialog-icon-bg)",
                "& .MuiSvgIcon-root": {
                    fontSize: "var(--icon-lg)",
                },
                //
                // The base styles give every `<i>` icon the muted text colour, so a Font Awesome icon
                // is told to take the badge's colour.
                //
                "& i": {
                    color: "inherit",
                },
            }}
            >
            {icon}
        </Box>
    );
}
