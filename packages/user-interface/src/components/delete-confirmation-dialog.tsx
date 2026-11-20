import React, { useState } from 'react';
import Button from '@mui/material/Button';
import DialogTitle from '@mui/material/DialogTitle';
import DialogContent from '@mui/material/DialogContent';
import DialogActions from '@mui/material/DialogActions';
import Typography from '@mui/material/Typography';
import { ResponsiveDialog } from './responsive-dialog';
import { DialogIconBadge } from './dialog-icon-badge';

export interface IProps {
    //
    // Set to true to display the dialog.
    //
    open: boolean;

    //
    // The number of items to be deleted.
    //
    numItems: number;

    //
    // Event raised to cancel the delete operation.
    //
    onCancel: () => void;

    //
    // Event raised to confirm the delete operation.
    //
    onDelete: () => Promise<void>;
}

export function DeleteConfirmationDialog({ open, numItems, onCancel, onDelete }: IProps) {
    
    const [working, setWorking] = useState(false);

    //
    // Runs the delete, tracking the in-progress state.
    //
    async function handleDelete(): Promise<void> {
        setWorking(true);
        try {
            await onDelete();
        }
        finally {
            setWorking(false);
        }
    }

    return (
        <ResponsiveDialog
            open={open}
            onClose={onCancel}
            minWidth={340}
            maxWidth={444}
            >
            <DialogTitle>
                <DialogIconBadge icon={<i className="fa-solid fa-trash-can" />} danger={true} />
                Delete Confirmation
            </DialogTitle>
            <DialogContent>
                <Typography
                    sx={{
                        color: 'var(--color-text-muted)',
                    }}
                    >
                    Are you sure you want to delete {numItems} assets? This cannot be undone.
                </Typography>
            </DialogContent>
            <DialogActions>
                <Button variant="outlined" onClick={onCancel}>
                    Cancel
                </Button>
                <Button
                    variant="outlined"
                    color="error"
                    disabled={working}
                    onClick={handleDelete}
                    >
                    Delete
                </Button>
            </DialogActions>
        </ResponsiveDialog>
    );
}
