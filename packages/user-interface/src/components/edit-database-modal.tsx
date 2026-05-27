import React, { useEffect, useState } from 'react';
import { log, logExceptions } from 'utils';
import Box from '@mui/joy/Box';
import Typography from '@mui/joy/Typography';
import Button from '@mui/joy/Button';
import Modal from '@mui/joy/Modal';
import ModalClose from '@mui/joy/ModalClose';
import ModalDialog from '@mui/joy/ModalDialog';
import DialogTitle from '@mui/joy/DialogTitle';
import DialogContent from '@mui/joy/DialogContent';
import DialogActions from '@mui/joy/DialogActions';
import Input from '@mui/joy/Input';
import FormControl from '@mui/joy/FormControl';
import FormLabel from '@mui/joy/FormLabel';
import { usePlatform, type IDatabaseEntry, type ISharedSecretEntry } from '../context/platform-context';
import { useApp } from '../context/app-context';
import { ConfigureSecretsModal, type IDatabaseSecretsSelection } from './configure-secrets-modal';

//
// Form state for the edit-database modal.
//
interface IEditDatabaseFormState {
    // Display name for the database.
    name: string;

    // Optional description.
    description: string;

    // Filesystem path or storage URI where the database lives.
    path: string;

    // Optional origin label distinguishing where this entry came from.
    origin: string;

    // Reference to the S3 credentials shared secret by id.
    s3Key: string | undefined;

    // Reference to the encryption-key shared secret by id.
    encryptionKey: string | undefined;

    // Reference to the geocoding API-key shared secret by id.
    geocodingKey: string | undefined;
}

//
// Props for EditDatabaseModal.
//
export interface IEditDatabaseModalProps {
    // Whether the modal is visible.
    open: boolean;

    // The entry being edited; undefined when adding a new entry.
    entry: IDatabaseEntry | undefined;

    // All existing database entries, used to detect name collisions inline.
    databases: IDatabaseEntry[];

    // Shared S3 credential secrets available for selection.
    s3Secrets: ISharedSecretEntry[];

    // Shared encryption-key secrets available for selection.
    encryptionSecrets: ISharedSecretEntry[];

    // Shared geocoding API-key secrets available for selection.
    geocodingSecrets: ISharedSecretEntry[];

    // Called when the modal should close (after save, cancel, or backdrop click).
    onClose: () => void;
}

//
// Returns a form state populated from the given entry, or empty state when no entry is given.
//
function formStateFor(entry: IDatabaseEntry | undefined): IEditDatabaseFormState {
    if (!entry) {
        return {
            name: '',
            description: '',
            path: '',
            origin: '',
            s3Key: undefined,
            encryptionKey: undefined,
            geocodingKey: undefined,
        };
    }
    return {
        name: entry.name,
        description: entry.description,
        path: entry.path,
        origin: entry.origin ?? '',
        s3Key: entry.s3Key,
        encryptionKey: entry.encryptionKey,
        geocodingKey: entry.geocodingKey,
    };
}

//
// Modal for editing an existing database entry, or adding a new one when entry is undefined.
//
export function EditDatabaseModal({
    open,
    entry,
    databases,
    s3Secrets,
    encryptionSecrets,
    geocodingSecrets,
    onClose,
}: IEditDatabaseModalProps) {
    const platform = usePlatform();
    const { addDatabase, updateDatabase } = useApp();

    // Current form values.
    const [form, setForm] = useState<IEditDatabaseFormState>(formStateFor(entry));

    // Inline name-conflict error shown under the Name field.
    const [nameError, setNameError] = useState<string | undefined>(undefined);

    // Whether the Configure Secrets modal is open over the dialog.
    const [secretsModalOpen, setSecretsModalOpen] = useState(false);

    // Reset the form each time the modal becomes visible so prior state does not leak into a new session.
    useEffect(() => {
        if (open) {
            setForm(formStateFor(entry));
            setNameError(undefined);
            if (entry) {
                log.info('Edit database dialog opened');
            }
        }
    }, [open, entry]);

    //
    // Opens a folder picker and sets the path field.
    //
    async function handleBrowse(): Promise<void> {
        const chosen = await platform.pickFolder();
        if (chosen) {
            setForm(prev => ({ ...prev, path: chosen }));
        }
    }

    //
    // Saves the secret selections chosen in the Configure Secrets modal back into the form state.
    //
    function handleSecretsSave(next: IDatabaseSecretsSelection): void {
        setForm(prev => ({ ...prev, s3Key: next.s3Key, encryptionKey: next.encryptionKey, geocodingKey: next.geocodingKey }));
        setSecretsModalOpen(false);
    }

    //
    // Returns a short summary of the selected secrets for display next to the Configure button.
    //
    function summariseSecrets(): string {
        const parts: string[] = [];
        if (form.s3Key) parts.push(`S3: ${form.s3Key}`);
        if (form.encryptionKey) parts.push(`Encryption: ${form.encryptionKey}`);
        if (form.geocodingKey) parts.push(`Geocoding: ${form.geocodingKey}`);
        return parts.length === 0 ? 'No secrets configured' : parts.join(' · ');
    }

    //
    // Saves the form (add or update entry). Sets `nameError` and aborts when the chosen
    // name conflicts with another existing entry (case-insensitive).
    //
    async function handleSave(): Promise<void> {
        setNameError(undefined);

        const trimmedName = form.name.trim();
        if (trimmedName.length === 0) {
            setNameError('Name is required');
            return;
        }

        const trimmedOrigin = form.origin.trim();
        const entryData: Omit<IDatabaseEntry, 'id'> = {
            name: trimmedName,
            description: form.description,
            path: form.path,
            origin: trimmedOrigin.length === 0 ? undefined : trimmedOrigin,
            s3Key: form.s3Key,
            encryptionKey: form.encryptionKey,
            geocodingKey: form.geocodingKey,
        };

        // Detect name collisions before submit so the user gets inline feedback rather
        // than an unhandled rejection from the storage-layer invariant.
        const isRenameToSelf = entry && entry.name.toLowerCase() === trimmedName.toLowerCase();
        if (!isRenameToSelf) {
            const collision = databases.find(existing => existing.name.toLowerCase() === trimmedName.toLowerCase());
            if (collision && (!entry || collision.name.toLowerCase() !== entry.name.toLowerCase())) {
                setNameError(`A database named "${trimmedName}" already exists.`);
                return;
            }
        }

        if (entry) {
            const originChanged = (entry.origin ?? '') !== (entryData.origin ?? '');
            if (originChanged) {
                await platform.setDatabaseOrigin(entryData.path, entryData.origin);
            }
            await updateDatabase(entry.name, { ...entry, ...entryData });
            log.event('Database entry updated');
        }
        else {
            await addDatabase(entryData);
        }

        onClose();
    }

    return (
        <>
            <Modal open={open} onClose={onClose}>
                <ModalDialog sx={{ minWidth: 500, maxWidth: 700, overflowY: 'auto' }}>
                    <ModalClose />
                    <DialogTitle>{entry ? 'Edit Database' : 'Add Database'}</DialogTitle>
                    <DialogContent>
                        <FormControl sx={{ mb: 1 }} error={nameError !== undefined}>
                            <FormLabel>Name</FormLabel>
                            <Input
                                value={form.name}
                                onChange={event => {
                                    setForm(prev => ({ ...prev, name: event.target.value }));
                                    setNameError(undefined);
                                }}
                            />
                            {nameError && (
                                <Typography level="body-sm" color="danger" sx={{ mt: 0.5 }}>
                                    {nameError}
                                </Typography>
                            )}
                        </FormControl>

                        <FormControl sx={{ mb: 1 }}>
                            <FormLabel>Description</FormLabel>
                            <Input
                                value={form.description}
                                onChange={event => setForm(prev => ({ ...prev, description: event.target.value }))}
                            />
                        </FormControl>

                        <FormControl sx={{ mb: 1 }}>
                            <FormLabel>Path</FormLabel>
                            <Box sx={{ display: 'flex', gap: 1 }}>
                                <Input
                                    sx={{ flexGrow: 1 }}
                                    value={form.path}
                                    onChange={event => setForm(prev => ({ ...prev, path: event.target.value }))}
                                />
                                <Button variant="outlined" onClick={() => handleBrowse().catch(err => log.exception('Browse error:', err as Error))}>
                                    Browse
                                </Button>
                            </Box>
                        </FormControl>

                        <FormControl sx={{ mb: 2 }}>
                            <FormLabel>Origin</FormLabel>
                            <Input
                                data-id="database-origin-input"
                                value={form.origin}
                                onChange={event => setForm(prev => ({ ...prev, origin: event.target.value }))}
                            />
                        </FormControl>

                        <FormControl sx={{ mb: 1 }}>
                            <FormLabel>Secrets</FormLabel>
                            <Box sx={{ display: 'flex', alignItems: 'center', gap: 1 }}>
                                <Typography level="body-sm" sx={{ flexGrow: 1 }} color="neutral">
                                    {summariseSecrets()}
                                </Typography>
                                <Button variant="outlined" size="sm" onClick={() => setSecretsModalOpen(true)}>
                                    Configure secrets…
                                </Button>
                            </Box>
                        </FormControl>
                    </DialogContent>
                    <DialogActions>
                        <Button variant="plain" onClick={onClose}>Cancel</Button>
                        <Button
                            data-id="save-database-button"
                            onClick={logExceptions(handleSave, 'Save error')}
                            >
                            Save
                        </Button>
                    </DialogActions>
                </ModalDialog>
            </Modal>

            <ConfigureSecretsModal
                open={secretsModalOpen}
                initialValue={{ s3Key: form.s3Key, encryptionKey: form.encryptionKey, geocodingKey: form.geocodingKey }}
                s3Secrets={s3Secrets}
                encryptionSecrets={encryptionSecrets}
                geocodingSecrets={geocodingSecrets}
                onSave={handleSecretsSave}
                onClose={() => setSecretsModalOpen(false)}
                quickCreateDefaultName={form.name || form.path}
            />
        </>
    );
}
