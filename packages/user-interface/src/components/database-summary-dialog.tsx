import React from "react";
import Button from "@mui/joy/Button";
import DialogActions from "@mui/joy/DialogActions";
import DialogContent from "@mui/joy/DialogContent";
import DialogTitle from "@mui/joy/DialogTitle";
import { ResponsiveDialog } from "./responsive-dialog";
import { DatabaseSummaryView } from "./database-summary-view";

export interface IDatabaseSummaryDialogProps {
    //
    // Whether the dialog is visible.
    //
    open: boolean;

    //
    // Called when the dialog should close.
    //
    onClose: () => void;
}

//
// Shows the summary of the open database: what is in it, where it lives, and its hashes.
//
// A modal on a desktop and a sheet on a phone, opened from the navbar's photo count. The count is
// the most glanced-at number in the app, so this is the detail behind it, one tap away rather than a
// trip through the sidebar to the Database Summary page.
//
export function DatabaseSummaryDialog({ open, onClose }: IDatabaseSummaryDialogProps) {
    return (
        <ResponsiveDialog
            open={open}
            onClose={onClose}
            minWidth={420}
            maxWidth={640}
            dataId="database-summary-dialog"
            >
            <DialogTitle>Database</DialogTitle>

            <DialogContent>
                {/*
                    Only while the dialog is open. On a phone the dialog is a Joy Drawer, which keeps
                    its children mounted when closed, so an unconditional view here ran the
                    get-database-summary task every time a database opened, for a dialog nobody had
                    asked for. It also makes the two forms behave alike: the desktop Modal unmounts
                    when closed, so there the summary already loaded on open.
                */}
                {open && <DatabaseSummaryView />}
            </DialogContent>

            <DialogActions>
                <Button data-id="database-summary-dialog-close" onClick={onClose}>Close</Button>
            </DialogActions>
        </ResponsiveDialog>
    );
}
