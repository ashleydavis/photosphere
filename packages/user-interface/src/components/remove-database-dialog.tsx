import React from 'react';
import { log } from 'utils';
import Button from '@mui/material/Button';
import DialogTitle from '@mui/material/DialogTitle';
import DialogContent from '@mui/material/DialogContent';
import DialogActions from '@mui/material/DialogActions';
import Typography from '@mui/material/Typography';
import { ResponsiveDialog } from './responsive-dialog';
import { DialogIconBadge } from './dialog-icon-badge';
import { type IDatabaseEntry } from '../context/platform-context';
import { useApp } from '../context/app-context';

//
// Props for RemoveDatabaseDialog.
//
export interface IRemoveDatabaseDialogProps {
    // Whether the dialog is visible.
    open: boolean;

    // The entry pending removal; undefined when no entry is selected.
    entry: IDatabaseEntry | undefined;

    // Called when the dialog should close (after confirm, cancel, or backdrop click).
    onClose: () => void;
}

//
// Confirmation dialog for removing a database entry from the configured list.
// Only removes the entry from configuration; files on disk are not deleted.
//
export function RemoveDatabaseDialog({ open, entry, onClose }: IRemoveDatabaseDialogProps) {
    const { removeDatabase } = useApp();

    //
    // Removes the entry from the database list, then closes the dialog.
    //
    async function handleConfirm(): Promise<void> {
        if (entry) {
            await removeDatabase(entry.name);
        }
        onClose();
    }

    return (
        <ResponsiveDialog
            open={open}
            onClose={onClose}
            minWidth={340}
            maxWidth={444}
            >
            <DialogTitle>
                <DialogIconBadge icon={<i className="fa-solid fa-trash-can" />} danger={true} />
                Remove Database Entry
            </DialogTitle>
            <DialogContent>
                <Typography>
                    Remove <strong>{entry?.name || entry?.path}</strong> from the list?
                </Typography>
                <Typography
                    variant="body2"
                    sx={{
                        marginTop: 'var(--space-2)',
                        color: 'var(--color-text-muted)',
                    }}
                    >
                    This only removes the entry from Photosphere's database list.
                    No files on disk will be deleted. Shared secrets are not affected.
                </Typography>
            </DialogContent>
            <DialogActions>
                <Button variant="outlined" onClick={onClose}>Cancel</Button>
                <Button
                    variant="outlined"
                    color="error"
                    onClick={() => handleConfirm().catch(err => log.exception('Remove error:', err as Error))}
                >
                    Remove
                </Button>
            </DialogActions>
        </ResponsiveDialog>
    );
}
