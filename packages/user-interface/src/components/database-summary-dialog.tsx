import React from "react";
import Button from "@mui/material/Button";
import DialogActions from "@mui/material/DialogActions";
import DialogContent from "@mui/material/DialogContent";
import DialogTitle from "@mui/material/DialogTitle";
import { ResponsiveDialog } from "./responsive-dialog";
import { DatabaseSummaryView } from "./database-summary-view";
import { DialogIconBadge } from "./dialog-icon-badge";
import { PieChart } from "@mui/icons-material";

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
// A modal on a desktop and a sheet on a mobile, opened from the navbar's photo count. The count is
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
            <DialogTitle><DialogIconBadge icon={<PieChart />} danger={false} />Database</DialogTitle>

            <DialogContent>
                {/*
                    Only while the dialog is open, so the get-database-summary task runs when the
                    user opens the dialog and never for a dialog the user has not asked for. A
                    Material Dialog or Drawer keeps its children mounted for the length of its
                    closing transition, and this unmounts the view the moment the dialog closes.
                */}
                {open && <DatabaseSummaryView />}
            </DialogContent>

            <DialogActions>
                <Button data-id="database-summary-dialog-close" variant="contained" onClick={onClose}>Close</Button>
            </DialogActions>
        </ResponsiveDialog>
    );
}
