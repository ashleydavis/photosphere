import React, { useEffect, useState } from 'react';
import { log, logExceptions } from 'utils';
import Box from '@mui/material/Box';
import Typography from '@mui/material/Typography';
import Button from '@mui/material/Button';
import IconButton from '@mui/material/IconButton';
import CloseIcon from '@mui/icons-material/Close';
import EditIcon from '@mui/icons-material/Edit';
import FolderOpenIcon from '@mui/icons-material/FolderOpen';
import { ResponsiveDialog } from './responsive-dialog';
import DialogTitle from '@mui/material/DialogTitle';
import DialogContent from '@mui/material/DialogContent';
import DialogActions from '@mui/material/DialogActions';
import OutlinedInput from '@mui/material/OutlinedInput';
import Select from '@mui/material/Select';
import MenuItem from '@mui/material/MenuItem';
import FormControl from '@mui/material/FormControl';
import FormLabel from '@mui/material/FormLabel';
import { usePlatform, type IDatabaseEntry, type ISharedSecretEntry } from '../context/platform-context';
import { useApp } from '../context/app-context';
import { ConfigureSecretsModal, type IDatabaseSecretsSelection } from './configure-secrets-modal';
import { createDialogKeyHandler } from '../lib/dialog-keys';
import { DialogIconBadge } from './dialog-icon-badge';
import { CARD_SX, cardRowSx, FIELD_LABEL_SX } from './create-database-modal';

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

    // The databases that can be picked as this one's origin: every entry but this one.
    //
    // Typing the origin by hand is what breaks syncing. The credentials for an origin are found by
    // matching its path against the database list, so a path with a typo in it finds no entry, gets
    // no credentials, and names a location that does not exist. Picking from the list cannot produce
    // either. The field stays typeable, because an origin that is not in the list is still allowed.
    const originCandidates = databases.filter(candidate => candidate.path !== form.path);

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
            path: form.path.trim(),
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
            // Written every save, not only when the field changed. The origin is kept in two places,
            // this entry and the database's own config, and only the second is what a sync reads.
            // Skipping the write when the entry already agrees assumes the two cannot disagree, and
            // when they do the disagreement is unfixable: the field shows the right origin, saving
            // does nothing, and the database goes on never syncing with nothing to say why.
            //
            // The entry is saved first because setting the origin opens the database's storage with the S3 secret of the
            // saved entry. Setting it first opened an S3 database with no credentials when its secret had just been
            // attached in this dialog, and the save failed with "Could not load credentials from any providers".
            await updateDatabase(entry.name, { ...entry, ...entryData });
            await platform.setDatabaseOrigin(entryData.path, entryData.origin);
            log.event('Database entry updated');
        }
        else {
            await addDatabase(entryData);
        }

        onClose();
    }

    return (
        <>
            <ResponsiveDialog
                open={open}
                onClose={onClose}
                minWidth={500}
                maxWidth={700}
                onKeyDown={createDialogKeyHandler(handleSave, false)}
                >
                    <IconButton
                        data-id="edit-database-close"
                        aria-label="Close"
                        onClick={onClose}
                        sx={{
                            position: 'absolute',
                            top: 'var(--space-4)',
                            right: 'var(--space-6)',
                        }}
                        >
                        <CloseIcon />
                    </IconButton>
                    <DialogTitle>
                        <DialogIconBadge icon={<EditIcon />} danger={false} />
                        {entry ? 'Edit Database' : 'Add Database'}
                    </DialogTitle>
                    <DialogContent>
                        <Box
                            sx={{
                                display: 'flex',
                                flexDirection: 'column',
                                gap: 'var(--space-4)',
                                paddingTop: 'var(--space-1)',
                            }}
                            >
                            <FormControl fullWidth error={nameError !== undefined}>
                                <FormLabel sx={FIELD_LABEL_SX}>Name</FormLabel>
                                <OutlinedInput
                                    size="small"
                                    data-id="edit-database-name-input"
                                    value={form.name}
                                    onChange={event => {
                                        setForm(prev => ({ ...prev, name: event.target.value }));
                                        setNameError(undefined);
                                    }}
                                />
                                {nameError && (
                                    <Typography
                                        variant="body2"
                                        sx={{
                                            marginTop: 'var(--space-1)',
                                            color: 'var(--color-danger)',
                                            fontSize: 'var(--text-sm)',
                                        }}
                                        >
                                        {nameError}
                                    </Typography>
                                )}
                            </FormControl>

                            <FormControl fullWidth>
                                <FormLabel sx={FIELD_LABEL_SX}>Description</FormLabel>
                                <OutlinedInput
                                    size="small"
                                    data-id="edit-database-description-input"
                                    value={form.description}
                                    onChange={event => setForm(prev => ({ ...prev, description: event.target.value }))}
                                />
                            </FormControl>

                            <FormControl fullWidth>
                                <FormLabel sx={FIELD_LABEL_SX}>Path</FormLabel>
                                <Box
                                    sx={{
                                        display: 'flex',
                                        alignItems: 'stretch',
                                        gap: 'var(--space-2)',
                                    }}
                                    >
                                    <OutlinedInput
                                        size="small"
                                        data-id="edit-database-path-input"
                                        sx={{
                                            flexGrow: 1,
                                            fontFamily: 'var(--font-mono)',
                                            fontSize: 'var(--text-sm)',
                                        }}
                                        value={form.path}
                                        onChange={event => setForm(prev => ({ ...prev, path: event.target.value }))}
                                    />
                                    {/* A mobile has no folder dialog for a database location: the user types its name instead. */}
                                    {platform.platformKind === "desktop" && (
                                        <Button
                                            data-id="edit-database-browse-button"
                                            variant="outlined"
                                            startIcon={<FolderOpenIcon />}
                                            sx={{
                                                flex: 'none',
                                                whiteSpace: 'nowrap',
                                            }}
                                            onClick={() => handleBrowse().catch(err => log.exception('Browse error:', err as Error))}
                                            >
                                            Browse
                                        </Button>
                                    )}
                                </Box>
                            </FormControl>

                            {/* The picker sits outside the FormControl, not beside the input inside it: a
                                FormControl takes only one input component, and a Select is one. */}
                            <Box
                                sx={{
                                    display: 'flex',
                                    alignItems: 'flex-end',
                                    gap: 'var(--space-2)',
                                }}
                                >
                                <FormControl
                                    fullWidth
                                    sx={{
                                        flexGrow: 1,
                                    }}
                                    >
                                    <FormLabel sx={FIELD_LABEL_SX}>Origin</FormLabel>
                                    <OutlinedInput
                                        size="small"
                                        data-id="database-origin-input"
                                        sx={{
                                            fontFamily: 'var(--font-mono)',
                                            fontSize: 'var(--text-sm)',
                                        }}
                                        value={form.origin}
                                        onChange={event => setForm(prev => ({ ...prev, origin: event.target.value }))}
                                    />
                                </FormControl>
                                {originCandidates.length > 0
                                    && <Select
                                        sx={{
                                            flex: 'none',
                                            minWidth: 'calc(var(--space-8) * 5)',
                                        }}
                                        size="small"
                                        value=""
                                        displayEmpty
                                        renderValue={() => 'Choose…'}
                                        onChange={event => {
                                            if (event.target.value) {
                                                setForm(prev => ({ ...prev, origin: event.target.value }));
                                            }
                                        }}
                                        data-id="database-origin-select"
                                    >
                                        {originCandidates.map(candidate => (
                                            <MenuItem
                                                data-id={`database-origin-option-${candidate.name}`}
                                                key={candidate.path}
                                                value={candidate.path}
                                                >
                                                {candidate.name}
                                            </MenuItem>
                                        ))}
                                    </Select>
                                }
                            </Box>

                            <FormControl fullWidth>
                                <FormLabel sx={FIELD_LABEL_SX}>Secrets</FormLabel>
                                <Box sx={CARD_SX}>
                                    <Box sx={cardRowSx(true)}>
                                        <Typography
                                            data-id="edit-database-secrets-summary"
                                            variant="body2"
                                            sx={{
                                                minWidth: 0,
                                                overflowWrap: 'anywhere',
                                                color: 'var(--color-text-muted)',
                                                fontSize: 'var(--text-sm)',
                                            }}
                                            >
                                            {summariseSecrets()}
                                        </Typography>
                                        <Button
                                            data-id="edit-database-configure-secrets-button"
                                            variant="outlined"
                                            size="small"
                                            sx={{
                                                flex: 'none',
                                            }}
                                            onClick={() => setSecretsModalOpen(true)}
                                            >
                                            Configure secrets…
                                        </Button>
                                    </Box>
                                </Box>
                            </FormControl>
                        </Box>
                    </DialogContent>
                    <DialogActions>
                        <Button data-id="edit-database-cancel" variant="outlined" onClick={onClose}>Cancel</Button>
                        <Button
                            data-id="save-database-button"
                            variant="contained"
                            onClick={logExceptions(handleSave, 'Save error')}
                            >
                            Save
                        </Button>
                    </DialogActions>
            </ResponsiveDialog>

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
