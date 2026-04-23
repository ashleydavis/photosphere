import React, { useState } from 'react';
import Box from '@mui/joy/Box';
import Modal from '@mui/joy/Modal';
import ModalDialog from '@mui/joy/ModalDialog';
import DialogTitle from '@mui/joy/DialogTitle';
import DialogContent from '@mui/joy/DialogContent';
import DialogActions from '@mui/joy/DialogActions';
import Button from '@mui/joy/Button';
import Input from '@mui/joy/Input';
import FormControl from '@mui/joy/FormControl';
import FormLabel from '@mui/joy/FormLabel';
import Select from '@mui/joy/Select';
import Option from '@mui/joy/Option';
import Switch from '@mui/joy/Switch';
import Typography from '@mui/joy/Typography';
import { usePlatform, type ISharedSecretEntry } from '../context/platform-context';
import { useAssetDatabase } from '../context/asset-database-source';
import { SelectSecretModal } from './select-secret-modal';
import { S3BrowserModal } from './s3-browser-modal';

export interface ICreateDatabaseModalProps {
    // Whether the modal is visible.
    open: boolean;

    // Called when the modal should close.
    onClose: () => void;
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
    const { openDatabase } = useAssetDatabase();

    const [form, setForm] = useState<ICreateDatabaseFormState>(emptyFormState());

    // Human-readable names for the currently selected secrets.
    const [s3SecretName, setS3SecretName] = useState<string | undefined>(undefined);
    const [encryptionSecretName, setEncryptionSecretName] = useState<string | undefined>(undefined);
    const [geocodingSecretName, setGeocodingSecretName] = useState<string | undefined>(undefined);

    // Which SelectSecretModal is currently open (undefined = none).
    const [selectSecretType, setSelectSecretType] = useState<string | undefined>(undefined);

    // Whether the S3 browser modal is open.
    const [s3BrowserOpen, setS3BrowserOpen] = useState(false);

    React.useEffect(() => {
        if (open) {
            setForm(emptyFormState());
            setS3SecretName(undefined);
            setEncryptionSecretName(undefined);
            setGeocodingSecretName(undefined);
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
    //
    async function handleCreate(): Promise<void> {
        await platform.addDatabase({
            name: form.name,
            description: form.description,
            path: form.path,
            s3Key: form.s3Key,
            encryptionKey: form.encryptionKey,
            geocodingKey: form.geocodingKey,
        });
        await platform.createDatabaseAtPath(form.path);
        await openDatabase(form.path);
        onClose();
    }

    //
    // Handles secret selection from SelectSecretModal.
    //
    function handleSecretSelected(secret: ISharedSecretEntry): void {
        if (selectSecretType === 's3-credentials') {
            setForm(prev => ({ ...prev, s3Key: secret.id }));
            setS3SecretName(secret.name);
        }
        else if (selectSecretType === 'encryption-key') {
            setForm(prev => ({ ...prev, encryptionKey: secret.id }));
            setEncryptionSecretName(secret.name);
        }
        else if (selectSecretType === 'api-key') {
            setForm(prev => ({ ...prev, geocodingKey: secret.id }));
            setGeocodingSecretName(secret.name);
        }
        setSelectSecretType(undefined);
    }

    //
    // Renders a secret selector row with the chosen secret's name and a button to open SelectSecretModal.
    //
    function renderSecretButton(
        label: string,
        secretType: string,
        chosenName: string | undefined
    ): React.ReactNode {
        return (
            <FormControl sx={{ mb: 1 }}>
                <FormLabel>{label}</FormLabel>
                <Box sx={{ display: 'flex', gap: 1, alignItems: 'center' }}>
                    <Typography level="body-sm" sx={{ flexGrow: 1 }}>
                        {chosenName ?? 'None selected'}
                    </Typography>
                    <Button
                        variant="outlined"
                        size="sm"
                        onClick={() => setSelectSecretType(secretType)}
                    >
                        Select
                    </Button>
                </Box>
            </FormControl>
        );
    }

    const browseDisabled = form.storageType === 's3' && !form.s3Key;

    return (
        <>
            <Modal open={open} onClose={onClose}>
                <ModalDialog sx={{ minWidth: 520, maxWidth: 700, overflowY: 'auto' }}>
                    <DialogTitle>New Database</DialogTitle>
                    <DialogContent>
                        <FormControl sx={{ mb: 1 }}>
                            <FormLabel>Name</FormLabel>
                            <Input
                                value={form.name}
                                onChange={event => setForm(prev => ({ ...prev, name: event.target.value }))}
                            />
                        </FormControl>

                        <FormControl sx={{ mb: 1 }}>
                            <FormLabel>Description</FormLabel>
                            <Input
                                value={form.description}
                                onChange={event => setForm(prev => ({ ...prev, description: event.target.value }))}
                            />
                        </FormControl>

                        <FormControl sx={{ mb: 2 }}>
                            <FormLabel>Type</FormLabel>
                            <Select
                                value={form.storageType}
                                onChange={(_event, value) => setForm(prev => ({ ...prev, storageType: value as StorageType, path: '', s3Key: undefined }))}
                            >
                                <Option value="filesystem">File system</Option>
                                <Option value="s3">S3</Option>
                            </Select>
                        </FormControl>

                        {form.storageType === 's3' && renderSecretButton('S3 Credentials', 's3-credentials', s3SecretName)}

                        <FormControl sx={{ mb: 2 }}>
                            <FormLabel>Path</FormLabel>
                            <Box sx={{ display: 'flex', gap: 1 }}>
                                <Input
                                    sx={{ flexGrow: 1 }}
                                    value={form.path}
                                    onChange={event => setForm(prev => ({ ...prev, path: event.target.value }))}
                                />
                                <Button
                                    variant="outlined"
                                    disabled={browseDisabled}
                                    onClick={() => handleBrowse().catch(err => console.error('Browse error:', err))}
                                >
                                    {form.storageType === 's3' ? 'Browse S3' : 'Browse'}
                                </Button>
                            </Box>
                        </FormControl>

                        <FormControl sx={{ mb: 2 }}>
                            <Box sx={{ display: 'flex', alignItems: 'center', gap: 1 }}>
                                <Switch
                                    checked={form.encrypted}
                                    onChange={event => setForm(prev => ({ ...prev, encrypted: event.target.checked, encryptionKey: undefined }))}
                                />
                                <FormLabel>Encrypted</FormLabel>
                            </Box>
                        </FormControl>

                        {form.encrypted && renderSecretButton('Encryption Key', 'encryption-key', encryptionSecretName)}

                        {renderSecretButton('Geocoding API Key (optional)', 'api-key', geocodingSecretName)}
                    </DialogContent>
                    <DialogActions>
                        <Button variant="plain" onClick={onClose}>Cancel</Button>
                        <Button
                            disabled={!form.path}
                            onClick={() => handleCreate().catch(err => console.error('Create database error:', err))}
                        >
                            Create
                        </Button>
                    </DialogActions>
                </ModalDialog>
            </Modal>

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
                    credentialId={form.s3Key}
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
