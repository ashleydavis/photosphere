import React, { useState } from 'react';
import { log } from 'utils';
import Button from '@mui/joy/Button';
import Modal from '@mui/joy/Modal';
import ModalDialog from '@mui/joy/ModalDialog';
import DialogTitle from '@mui/joy/DialogTitle';
import DialogContent from '@mui/joy/DialogContent';
import DialogActions from '@mui/joy/DialogActions';
import Typography from '@mui/joy/Typography';
import CircularProgress from '@mui/joy/CircularProgress';
import { usePlatform } from '../context/platform-context';
import { useApp } from '../context/app-context';
import { useAssetDatabase } from '../context/asset-database-source';
import { useToast } from '../context/toast-context';
import { resetDevice } from '../lib/reset-device';
import { runResetAppStorageTask } from '../lib/reset-app-storage-task';

//
// Props for ResetDeviceDialog.
//
export interface IResetDeviceDialogProps {
    // Whether the dialog is visible.
    open: boolean;

    // Called when the dialog should close (after the reset, cancel, or backdrop click).
    onClose: () => void;
}

//
// Two-step confirmation for resetting the device: the first step says what will go, the second is
// the last chance to stop. Two steps because none of it can be undone.
//
export function ResetDeviceDialog({ open, onClose }: IResetDeviceDialogProps) {
    const platform = usePlatform();
    const { dbs, secrets, refresh } = useApp();
    const { closeDatabase } = useAssetDatabase();
    const { addToast } = useToast();

    //
    // True once the user has passed the first step and is being asked for the last time.
    //
    const [finalConfirmation, setFinalConfirmation] = useState<boolean>(false);

    //
    // True while the reset is running, so the confirm button cannot be pressed twice.
    //
    const [resetting, setResetting] = useState<boolean>(false);

    //
    // Closes the dialog and puts it back to its first step, so opening it again does not land the
    // user on the final confirmation.
    //
    function handleClose(): void {
        setFinalConfirmation(false);
        onClose();
    }

    //
    // Runs the reset, re-reads the lists so the app shows the empty state it is now in, and closes.
    //
    async function handleReset(): Promise<void> {
        setResetting(true);
        try {
            const result = await resetDevice({
                closeDatabase,
                getDatabases: platform.getDatabases,
                removeDatabaseEntry: platform.removeDatabaseEntry,
                listSecrets: platform.listSecrets,
                deleteSecret: platform.deleteSecret,
                settingsStore: {
                    keys: () => Object.keys(window.localStorage),
                    removeItem: (key: string) => window.localStorage.removeItem(key),
                },
                resetAppStorage: runResetAppStorageTask,
            });
            // Re-read before the line is written, so anything waiting on it (the smoke tests, and a
            // user watching the lists) sees the empty state rather than the one being replaced.
            await refresh();
            log.info(`Device reset: removed ${result.databasesRemoved} databases, ${result.secretsRemoved} secrets, ${result.settingsRemoved} settings and ${result.storageEntriesRemoved} entries from the app's storage`);
            handleClose();
        }
        catch (error) {
            // Loud, and stays on screen: a user handing a phone on has to know the reset did not
            // finish and their credentials may still be on it.
            log.exception('Device reset failed:', error as Error);
            addToast({
                message: `The reset did not finish: ${(error as Error).message}. Some databases or secrets may still be on this device.`,
                color: 'danger',
                duration: 0,
            });
            handleClose();
        }
        finally {
            setResetting(false);
        }
    }

    return (
        <Modal open={open} onClose={handleClose}>
            <ModalDialog data-id="reset-device-dialog">
                <DialogTitle>{finalConfirmation ? 'Reset this device?' : 'Reset device'}</DialogTitle>
                {!finalConfirmation
                    && <>
                        <DialogContent>
                            <Typography>
                                This removes everything Photosphere keeps on this device:
                                {' '}<strong data-id="reset-device-database-count">{dbs.length}</strong> database{dbs.length === 1 ? '' : 's'}
                                {' '}and <strong data-id="reset-device-secret-count">{secrets.length}</strong> secret{secrets.length === 1 ? '' : 's'},
                                {' '}along with its settings and its caches.
                            </Typography>
                            <Typography level="body-sm" sx={{ mt: 1 }}>
                                <strong>Your photos go with it.</strong> The databases the app keeps
                                on this device are deleted, and every photo in them. If you have used
                                Free up space on this device, they are the only copy of those photos.
                            </Typography>
                            <Typography level="body-sm" sx={{ mt: 1 }}>
                                <strong>Your encryption keys go too.</strong> They are stored as
                                secrets on this device, and an encrypted database cannot be opened
                                again without them.
                            </Typography>
                            <Typography level="body-sm" sx={{ mt: 1 }}>
                                This cannot be undone.
                            </Typography>
                        </DialogContent>
                        <DialogActions>
                            <Button data-id="reset-device-cancel" variant="plain" onClick={handleClose}>Cancel</Button>
                            <Button
                                data-id="reset-device-continue"
                                color="danger"
                                onClick={() => setFinalConfirmation(true)}
                            >
                                Continue
                            </Button>
                        </DialogActions>
                    </>
                }
                {finalConfirmation
                    && <>
                        <DialogContent>
                            <Typography>
                                Last chance. Resetting deletes the app's databases and the photos in
                                them, its secrets including your encryption keys, its settings and
                                its caches. None of it can be brought back.
                            </Typography>
                        </DialogContent>
                        <DialogActions>
                            <Button data-id="reset-device-final-cancel" variant="plain" onClick={handleClose} disabled={resetting}>Cancel</Button>
                            <Button
                                data-id="reset-device-confirm"
                                color="danger"
                                disabled={resetting}
                                startDecorator={resetting ? <CircularProgress size="sm" /> : undefined}
                                onClick={() => { void handleReset(); }}
                            >
                                Reset device
                            </Button>
                        </DialogActions>
                    </>
                }
            </ModalDialog>
        </Modal>
    );
}
