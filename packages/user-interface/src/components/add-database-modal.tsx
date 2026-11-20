import React, { useState } from 'react';
import { log } from 'utils';
import Box from '@mui/material/Box';
import { ResponsiveDialog } from './responsive-dialog';
import DialogTitle from '@mui/material/DialogTitle';
import DialogContent from '@mui/material/DialogContent';
import DialogActions from '@mui/material/DialogActions';
import Button from '@mui/material/Button';
import OutlinedInput from '@mui/material/OutlinedInput';
import FormControl from '@mui/material/FormControl';
import FormLabel from '@mui/material/FormLabel';
import Select from '@mui/material/Select';
import MenuItem from '@mui/material/MenuItem';
import Switch from '@mui/material/Switch';
import Typography from '@mui/material/Typography';
import FolderOpenIcon from '@mui/icons-material/FolderOpen';
import AddIcon from '@mui/icons-material/Add';
import { usePlatform, type ISharedSecretEntry } from '../context/platform-context';
import { useApp } from '../context/app-context';
import { useAssetDatabase } from '../context/asset-database-source';
import { SelectSecretModal } from './select-secret-modal';
import { S3BrowserModal } from './s3-browser-modal';
import { createDialogKeyHandler } from '../lib/dialog-keys';
import { DialogIconBadge } from './dialog-icon-badge';
import { CARD_SX, cardRowSx, FIELD_LABEL_SX } from './create-database-modal';

export interface IAddDatabaseModalProps {
    // Whether the modal is visible.
    open: boolean;

    // Called when the modal should close.
    onClose: () => void;
}

//
// Storage type selection for adding a database.
//
type StorageType = 'filesystem' | 's3';

//
// Form state for the add-database modal.
//
interface IAddDatabaseFormState {
    // Display name for the database.
    name: string;

    // Optional description.
    description: string;

    // Absolute filesystem path or S3 path where the database lives.
    path: string;

    // Storage back-end type.
    storageType: StorageType;

    // Whether the database uses encryption.
    encrypted: boolean;

    // Optional shared secret id for S3 credentials.
    s3Key: string | undefined;

    // Optional shared secret id for the encryption key pair.
    encryptionKey: string | undefined;

    // Optional shared secret id for the geocoding API key.
    geocodingKey: string | undefined;
}

//
// Returns an empty form state.
//
function emptyFormState(): IAddDatabaseFormState {
    return {
        name: '',
        description: '',
        path: '',
        storageType: 'filesystem',
        encrypted: false,
        s3Key: undefined,
        encryptionKey: undefined,
        geocodingKey: undefined,
    };
}

//
// Modal for registering an existing database (no initialisation step).
//
export function AddDatabaseModal({ open, onClose }: IAddDatabaseModalProps) {
    const platform = usePlatform();
    const { addDatabase } = useApp();
    const { openDatabase } = useAssetDatabase();

    const [form, setForm] = useState<IAddDatabaseFormState>(emptyFormState());

    // Human-readable names for the currently selected secrets.
    const [s3SecretName, setS3SecretName] = useState<string | undefined>(undefined);
    const [encryptionSecretName, setEncryptionSecretName] = useState<string | undefined>(undefined);
    const [geocodingSecretName, setGeocodingSecretName] = useState<string | undefined>(undefined);

    // Which SelectSecretModal is currently open (undefined = none).
    const [selectSecretType, setSelectSecretType] = useState<string | undefined>(undefined);

    // Whether the S3 browser modal is open.
    const [s3BrowserOpen, setS3BrowserOpen] = useState(false);

    // Inline name-conflict error shown under the Name field.
    const [nameError, setNameError] = useState<string | undefined>(undefined);

    React.useEffect(() => {
        if (open) {
            setForm(emptyFormState());
            setS3SecretName(undefined);
            setEncryptionSecretName(undefined);
            setGeocodingSecretName(undefined);
            setNameError(undefined);
            log.info('Add database dialog opened');
        }
    }, [open]);

    //
    // Opens a folder picker (filesystem) or S3 browser and sets the path field.
    //
    async function handleBrowse(): Promise<void> {
        if (form.storageType === 'filesystem') {
            const chosen = await platform.pickFolder();
            if (chosen) {
                setForm(prev => ({ ...prev, path: chosen }));
            }
        }
        else {
            setS3BrowserOpen(true);
        }
    }

    //
    // Registers the database entry and opens it.
    // Validates that the chosen name does not collide with an existing entry first;
    // any collision is shown as inline error text under the Name field.
    //
    async function handleAdd(): Promise<void> {
        const trimmedName = form.name.trim();
        if (trimmedName.length === 0) {
            setNameError('Name is required');
            return;
        }
        const existing = await platform.findDatabase(trimmedName);
        if (existing) {
            setNameError(`A database named "${trimmedName}" already exists.`);
            return;
        }
        await addDatabase({
            name: trimmedName,
            description: form.description,
            path: form.path.trim(),
            s3Key: form.s3Key,
            encryptionKey: form.encryptionKey,
            geocodingKey: form.geocodingKey,
        });
        await openDatabase(form.path.trim());
        onClose();
    }

    //
    // Handles secret selection from SelectSecretModal.
    //
    function handleSecretSelected(secret: ISharedSecretEntry): void {
        if (selectSecretType === 's3-credentials') {
            setForm(prev => ({ ...prev, s3Key: secret.name }));
            setS3SecretName(secret.name);
        }
        else if (selectSecretType === 'encryption-key') {
            setForm(prev => ({ ...prev, encryptionKey: secret.name }));
            setEncryptionSecretName(secret.name);
        }
        else if (selectSecretType === 'api-key') {
            setForm(prev => ({ ...prev, geocodingKey: secret.name }));
            setGeocodingSecretName(secret.name);
        }
        setSelectSecretType(undefined);
    }

    //
    // Renders a secret selector row with the chosen secret's name and a button to open SelectSecretModal.
    // `first` leaves off the divider above the row when it is the first row of its card.
    //
    function renderSecretButton(
        label: string,
        secretType: string,
        chosenName: string | undefined,
        chosenNameDataId: string | undefined,
        buttonDataId: string,
        first: boolean
    ): React.ReactNode {
        return (
            <Box sx={cardRowSx(first)}>
                <Box
                    sx={{
                        display: 'flex',
                        flexDirection: 'column',
                        minWidth: 0,
                    }}
                    >
                    <Typography
                        variant="body2"
                        sx={{
                            color: 'var(--color-text)',
                            fontSize: 'var(--text-md)',
                        }}
                        >
                        {label}
                    </Typography>
                    <Typography
                        data-id={chosenNameDataId}
                        variant="body2"
                        sx={{
                            overflowWrap: 'anywhere',
                            color: 'var(--color-text-muted)',
                            fontSize: 'var(--text-sm)',
                        }}
                        >
                        {chosenName ?? 'None selected'}
                    </Typography>
                </Box>
                <Button
                    data-id={buttonDataId}
                    variant="outlined"
                    size="small"
                    sx={{
                        flex: 'none',
                    }}
                    onClick={() => setSelectSecretType(secretType)}
                >
                    Select
                </Button>
            </Box>
        );
    }

    const browseDisabled = form.storageType === 's3' && !form.s3Key;

    // A mobile has no folder dialog for a database location: the user types the database's name into the Path field instead.
    const showBrowse = form.storageType === 's3' || platform.platformKind === "desktop";

    return (
        <>
            <ResponsiveDialog
                open={open}
                onClose={onClose}
                minWidth={520}
                maxWidth={700}
                onKeyDown={createDialogKeyHandler(handleAdd, !form.path)}
                >
                    <DialogTitle>
                        <DialogIconBadge icon={<AddIcon />} danger={false} />
                        Add Database
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
                                    data-id="database-name-input"
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
                                    value={form.description}
                                    onChange={event => setForm(prev => ({ ...prev, description: event.target.value }))}
                                />
                            </FormControl>

                            <FormControl fullWidth>
                                <FormLabel sx={FIELD_LABEL_SX}>Type</FormLabel>
                                <Select
                                    value={form.storageType}
                                    size="small"
                                    onChange={event => setForm(prev => ({ ...prev, storageType: event.target.value as StorageType, path: '', s3Key: undefined }))}
                                    data-id="database-storage-type-select"
                                >
                                    <MenuItem value="filesystem">File system</MenuItem>
                                    <MenuItem data-id="database-storage-type-option-s3" value="s3">S3</MenuItem>
                                </Select>
                            </FormControl>

                            {form.storageType === 's3' && (
                                <Box sx={CARD_SX}>
                                    {renderSecretButton('S3 Credentials', 's3-credentials', s3SecretName, 'chosen-s3-secret', 'select-s3-button', true)}
                                </Box>
                            )}

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
                                        data-id="database-path-input"
                                        sx={{
                                            flexGrow: 1,
                                            fontFamily: 'var(--font-mono)',
                                            fontSize: 'var(--text-sm)',
                                        }}
                                        value={form.path}
                                        placeholder={showBrowse ? undefined : 'Type the name of the database'}
                                        onChange={event => setForm(prev => ({ ...prev, path: event.target.value }))}
                                    />
                                    {showBrowse && (
                                        <Button
                                            data-id="database-browse-button"
                                            variant="outlined"
                                            disabled={browseDisabled}
                                            startIcon={<FolderOpenIcon />}
                                            sx={{
                                                flex: 'none',
                                                whiteSpace: 'nowrap',
                                            }}
                                            onClick={() => handleBrowse().catch(err => log.exception('Browse error:', err as Error))}
                                        >
                                            {form.storageType === 's3' ? 'Browse S3' : 'Browse'}
                                        </Button>
                                    )}
                                </Box>
                            </FormControl>

                            <Box sx={CARD_SX}>
                                <Box sx={cardRowSx(true)}>
                                    <FormLabel
                                        sx={{
                                            color: 'var(--color-text)',
                                            '&.Mui-focused': {
                                                color: 'var(--color-text)',
                                            },
                                        }}
                                        >
                                        Encrypted
                                    </FormLabel>
                                    <Switch
                                        data-id="database-encrypted-switch"
                                        checked={form.encrypted}
                                        onChange={event => setForm(prev => ({ ...prev, encrypted: event.target.checked, encryptionKey: undefined }))}
                                    />
                                </Box>
                                {form.encrypted && renderSecretButton('Encryption Key', 'encryption-key', encryptionSecretName, 'chosen-encryption-secret', 'select-encryption-button', false)}
                            </Box>

                            <Box sx={CARD_SX}>
                                {renderSecretButton('Geocoding API Key (optional)', 'api-key', geocodingSecretName, 'chosen-geocoding-secret', 'select-geocoding-button', true)}
                            </Box>
                        </Box>
                    </DialogContent>
                    <DialogActions>
                        <Button data-id="add-database-cancel" variant="outlined" onClick={onClose}>Cancel</Button>
                        <Button
                            data-id="add-database-confirm"
                            variant="contained"
                            disabled={!form.path}
                            onClick={() => handleAdd().catch(err => log.exception('Add database error:', err as Error))}
                        >
                            Add
                        </Button>
                    </DialogActions>
            </ResponsiveDialog>

            {selectSecretType !== undefined && (
                <SelectSecretModal
                    open={true}
                    secretType={selectSecretType}
                    onClose={() => setSelectSecretType(undefined)}
                    onSelect={handleSecretSelected}
                />
            )}

            {s3BrowserOpen && form.s3Key && (
                <S3BrowserModal
                    open={true}
                    s3Key={form.s3Key}
                    onClose={() => setS3BrowserOpen(false)}
                    onSelect={path => {
                        setForm(prev => ({ ...prev, path }));
                        setS3BrowserOpen(false);
                    }}
                />
            )}
        </>
    );
}
