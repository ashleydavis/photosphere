import React from 'react';
import { log } from 'utils';
import Button from '@mui/joy/Button';
import Modal from '@mui/joy/Modal';
import ModalDialog from '@mui/joy/ModalDialog';
import DialogTitle from '@mui/joy/DialogTitle';
import DialogContent from '@mui/joy/DialogContent';
import DialogActions from '@mui/joy/DialogActions';
import Typography from '@mui/joy/Typography';
import { type IDatabaseEntry } from '../context/platform-context';
import { useApp } from '../context/app-context';
import { createDialogKeyHandler } from '../lib/dialog-keys';

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
        <Modal open={open} onClose={onClose}>
            <ModalDialog onKeyDown={createDialogKeyHandler(handleConfirm, false)}>
                <DialogTitle>Remove Database Entry</DialogTitle>
                <DialogContent>
                    <Typography>
                        Remove <strong>{entry?.name || entry?.path}</strong> from the list?
                    </Typography>
                    <Typography level="body-sm" sx={{ mt: 1 }}>
                        This only removes the entry from Photosphere's database list.
                        No files on disk will be deleted. Shared secrets are not affected.
                    </Typography>
                </DialogContent>
                <DialogActions>
                    <Button variant="plain" onClick={onClose}>Cancel</Button>
                    <Button
                        color="danger"
                        onClick={() => handleConfirm().catch(err => log.exception('Remove error:', err as Error))}
                    >
                        Remove
                    </Button>
                </DialogActions>
            </ModalDialog>
        </Modal>
    );
}
