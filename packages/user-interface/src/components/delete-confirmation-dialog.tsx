import React, { useState } from 'react';
import Button from '@mui/material/Button';
import Dialog from '@mui/material/Dialog';
import DialogTitle from '@mui/material/DialogTitle';
import DialogContent from '@mui/material/DialogContent';
import DialogActions from '@mui/material/DialogActions';
import Typography from '@mui/material/Typography';

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
        <Dialog
            open={open}
            onClose={onCancel}
            >
            <DialogTitle>
                Delete Confirmation
            </DialogTitle>
            <DialogContent>
                <Typography>
                    Are you sure you want to delete {numItems} assets? This cannot be undone.
                </Typography>
            </DialogContent>
            <DialogActions>
                <Button variant="text" onClick={onCancel}>
                    Cancel
                </Button>
                <div className="flex-grow" />
                <Button
                    variant="contained"
                    color="error"
                    disabled={working}
                    onClick={handleDelete}
                    >
                    Delete
                </Button>
            </DialogActions>
        </Dialog>
    );
}
