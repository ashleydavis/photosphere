import React, { useState } from 'react';
import { log } from 'utils';
import Box from '@mui/material/Box';
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
import StorageIcon from '@mui/icons-material/Storage';
import { type SxProps, type Theme } from '@mui/material/styles';
import { usePlatform, type ISharedSecretEntry } from '../context/platform-context';
import { useApp } from '../context/app-context';
import { useAssetDatabase } from '../context/asset-database-source';
import { SelectSecretModal } from './select-secret-modal';
import { S3BrowserModal } from './s3-browser-modal';
import { createDialogKeyHandler } from '../lib/dialog-keys';
import { DialogIconBadge } from './dialog-icon-badge';
import { ResponsiveDialog } from './responsive-dialog';

export interface ICreateDatabaseModalProps {
    // Whether the modal is visible.
    open: boolean;

    // Called when the modal should close.
    onClose: () => void;
}

//
// The look of a field's label over its box, as the style guide's dialogs label a group of
// controls: muted, small and bold. The focused and error colours MUI gives a label are replaced so
// the label keeps the token colours.
//
export const FIELD_LABEL_SX: SxProps<Theme> = {
    marginBottom: "var(--space-1)",
    color: "var(--color-text-muted)",
    fontSize: "var(--text-sm)",
    fontWeight: "var(--weight-bold)",
    "&.Mui-focused": {
        color: "var(--color-text-muted)",
    },
    "&.Mui-error": {
        color: "var(--color-danger)",
    },
};

//
// The look of a card of rows, the settings card the style guide groups a dialog's switches and
// linked secrets in.
//
export const CARD_SX: SxProps<Theme> = {
    display: "flex",
    flexDirection: "column",
    overflow: "hidden",
    backgroundColor: "var(--color-settings-section-bg)",
    border: "var(--list-divider-width) solid var(--color-settings-section-border)",
    borderRadius: "var(--radius-settings-section)",
};

//
// Returns the look of one row of a card: its label at the left and its control at the right, with
// a divider above every row but the first, so the card's own edge is the only line above the first.
//
export function cardRowSx(first: boolean): SxProps<Theme> {
    let borderTop = "var(--settings-row-divider-width) solid var(--color-border)";
    if (first) {
        borderTop = "none";
    }
    return {
        display: "flex",
        alignItems: "center",
        justifyContent: "space-between",
        gap: "var(--space-3)",
        minHeight: "calc(var(--space-8) + var(--space-6))",
        padding: "var(--space-2) var(--space-3)",
        borderTop,
    };
}

//
// Storage type selection for a new database.
//
type StorageType = 'filesystem' | 's3';

//
// Form state for the create-database modal.
//
interface ICreateDatabaseFormState {
    // Display name for the database.
    name: string;

    // Optional description.
    description: string;

    // Absolute filesystem path or S3 path where the database will be created.
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
function emptyFormState(): ICreateDatabaseFormState {
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
// Modal for creating a new database entry and initialising the database on disk.
//
export function CreateDatabaseModal({ open, onClose }: ICreateDatabaseModalProps) {
    const platform = usePlatform();
    const { addDatabase } = useApp();
    const { createDatabaseAtPath } = useAssetDatabase();

    const [form, setForm] = useState<ICreateDatabaseFormState>(emptyFormState());

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

    // The error of the last Create that failed, shown above the dialog's buttons.
    const [createError, setCreateError] = useState<string | undefined>(undefined);

    React.useEffect(() => {
        if (open) {
            setForm(emptyFormState());
            setS3SecretName(undefined);
            setEncryptionSecretName(undefined);
            setGeocodingSecretName(undefined);
            setNameError(undefined);
            setCreateError(undefined);
            log.info('Create database dialog opened');
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
    // Creates the database entry, initialises the database on disk, and opens it.
    // Validates that the chosen name does not collide with an existing entry first;
    // any collision is shown as inline error text under the Name field.
    //
    async function handleCreate(): Promise<void> {
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
        await createDatabaseAtPath(form.path.trim());
        log.info(`Database created: ${form.path.trim()}`);
        onClose();
    }

    //
    // Runs Create from the button or the Enter key, and shows any error it fails with in the dialog.
    //
    async function createAndShowError(): Promise<void> {
        setCreateError(undefined);
        try {
            await handleCreate();
        }
        catch (err) {
            log.exception('Create database error:', err as Error);
            setCreateError(err instanceof Error ? err.message : String(err));
        }
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

    // A mobile has no folder dialog for a database location: the user types a name into the Path field instead.
    const showBrowse = form.storageType === 's3' || platform.platformKind === "desktop";

    return (
        <>
            <ResponsiveDialog
                open={open}
                onClose={onClose}
                minWidth={520}
                maxWidth={700}
                onKeyDown={createDialogKeyHandler(createAndShowError, !form.path || nameError !== undefined)}
                >
                <DialogTitle>
                    <DialogIconBadge icon={<StorageIcon />} danger={false} />
                    New Database
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
                                    placeholder={showBrowse ? undefined : 'Type a name for the database'}
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
                                    checked={form.encrypted}
                                    onChange={event => setForm(prev => ({ ...prev, encrypted: event.target.checked, encryptionKey: undefined }))}
                                />
                            </Box>
                            {form.encrypted && renderSecretButton('Encryption Key', 'encryption-key', encryptionSecretName, undefined, 'select-encryption-button', false)}
                        </Box>

                        <Box sx={CARD_SX}>
                            {renderSecretButton('Geocoding API Key (optional)', 'api-key', geocodingSecretName, undefined, 'select-geocoding-button', true)}
                        </Box>

                        {createError && (
                            <Typography
                                data-id="create-database-error"
                                variant="body2"
                                sx={{
                                    color: 'var(--color-danger)',
                                }}
                                >
                                {createError}
                            </Typography>
                        )}
                    </Box>
                </DialogContent>
                <DialogActions>
                    <Button data-id="create-database-cancel" variant="outlined" onClick={onClose}>Cancel</Button>
                    <Button
                        data-id="create-database-confirm"
                        variant="contained"
                        disabled={!form.path || nameError !== undefined}
                        onClick={createAndShowError}
                    >
                        Create
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
