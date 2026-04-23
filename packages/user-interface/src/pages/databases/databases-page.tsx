import React, { useEffect, useState } from 'react';
import Box from '@mui/joy/Box';
import Typography from '@mui/joy/Typography';
import Button from '@mui/joy/Button';
import Table from '@mui/joy/Table';
import IconButton from '@mui/joy/IconButton';
import Modal from '@mui/joy/Modal';
import ModalClose from '@mui/joy/ModalClose';
import ModalDialog from '@mui/joy/ModalDialog';
import DialogTitle from '@mui/joy/DialogTitle';
import DialogContent from '@mui/joy/DialogContent';
import DialogActions from '@mui/joy/DialogActions';
import Input from '@mui/joy/Input';
import FormControl from '@mui/joy/FormControl';
import FormLabel from '@mui/joy/FormLabel';
import Select from '@mui/joy/Select';
import Option from '@mui/joy/Option';
import { Edit, Delete, Refresh, FolderOpen } from '@mui/icons-material';
import { useNavigate } from 'react-router-dom';
import { usePlatform, type IDatabaseEntry, type ISharedSecretEntry } from '../../context/platform-context';
import { useAssetDatabase } from '../../context/asset-database-source';
import { CreateSecretDialog } from '../../components/create-secret-dialog';
import { CreateDatabaseModal } from '../../components/create-database-modal';
import { AddDatabaseModal } from '../../components/add-database-modal';

//
// Form state for the add/edit dialog.
//
interface IDatabaseFormState {
    // Non-secret fields.
    name: string;
    description: string;
    path: string;

    // References to shared secrets by id.
    s3Key: string | undefined;
    encryptionKey: string | undefined;
    geocodingKey: string | undefined;
}

//
// Returns an empty form state.
//
function emptyFormState(): IDatabaseFormState {
    return {
        name: '',
        description: '',
        path: '',
        s3Key: undefined,
        encryptionKey: undefined,
        geocodingKey: undefined,
    };
}

//
// Full CRUD management page for configured database entries.
//
export function DatabasesPage() {
    const platform = usePlatform();
    const { openDatabase } = useAssetDatabase();
    const navigate = useNavigate();

    // All known database entries.
    const [databases, setDatabases] = useState<IDatabaseEntry[]>([]);

    // Shared secrets grouped by type.
    const [s3Secrets, setS3Secrets] = useState<ISharedSecretEntry[]>([]);
    const [encryptionSecrets, setEncryptionSecrets] = useState<ISharedSecretEntry[]>([]);
    const [geocodingSecrets, setGeocodingSecrets] = useState<ISharedSecretEntry[]>([]);

    // Whether the create-database modal is open.
    const [createModalOpen, setCreateModalOpen] = useState(false);

    // Whether the add-database modal is open.
    const [addModalOpen, setAddModalOpen] = useState(false);

    // Whether the add/edit dialog is open.
    const [dialogOpen, setDialogOpen] = useState(false);

    // Entry being edited (undefined when adding new).
    const [editingEntry, setEditingEntry] = useState<IDatabaseEntry | undefined>(undefined);

    // Current form values.
    const [form, setForm] = useState<IDatabaseFormState>(emptyFormState());

    // Whether the remove confirmation dialog is open.
    const [confirmRemoveOpen, setConfirmRemoveOpen] = useState(false);

    // Entry pending removal.
    const [removingEntry, setRemovingEntry] = useState<IDatabaseEntry | undefined>(undefined);

    // Whether a quick-create secret dialog is open and which type it is for.
    const [quickCreateType, setQuickCreateType] = useState<string | undefined>(undefined);

    // Whether a refresh is in progress (drives the spin animation).
    const [refreshing, setRefreshing] = useState(false);

    //
    // Loads database entries and secrets from the platform.
    //
    async function loadData(): Promise<void> {
        const [entries, allSecrets] = await Promise.all([
            platform.getDatabases(),
            platform.listSecrets(),
        ]);
        setDatabases(entries);
        setS3Secrets(allSecrets.filter(secret => secret.type === 's3-credentials'));
        setEncryptionSecrets(allSecrets.filter(secret => secret.type === 'encryption-key'));
        setGeocodingSecrets(allSecrets.filter(secret => secret.type === 'api-key'));
    }

    useEffect(() => {
        loadData().catch(err => console.error('Failed to load data:', err));
    }, []);

    //
    // Reloads data with a minimum delay so the spin animation is visible.
    //
    async function handleRefresh(): Promise<void> {
        setRefreshing(true);
        await Promise.all([
            loadData(),
            new Promise(resolve => setTimeout(resolve, 500)),
        ]);
        setRefreshing(false);
    }

    //
    // Opens the add dialog with a blank form.
    //
    function openAddDialog(): void {
        setEditingEntry(undefined);
        setForm(emptyFormState());
        setDialogOpen(true);
    }

    //
    // Opens the edit dialog pre-populated with the entry's values.
    //
    function openEditDialog(entry: IDatabaseEntry): void {
        setEditingEntry(entry);
        setForm({
            name: entry.name,
            description: entry.description,
            path: entry.path,
            s3Key: entry.s3Key,
            encryptionKey: entry.encryptionKey,
            geocodingKey: entry.geocodingKey,
        });
        setDialogOpen(true);
    }

    //
    // Saves the form (add or update entry).
    //
    async function handleSave(): Promise<void> {
        const entryData: Omit<IDatabaseEntry, 'id'> = {
            name: form.name,
            description: form.description,
            path: form.path,
            s3Key: form.s3Key,
            encryptionKey: form.encryptionKey,
            geocodingKey: form.geocodingKey,
        };

        if (editingEntry) {
            await platform.updateDatabase({ ...editingEntry, ...entryData });
        }
        else {
            await platform.addDatabase(entryData);
        }

        setDialogOpen(false);
        await loadData();
    }

    //
    // Opens the remove confirmation dialog for the given entry.
    //
    function promptRemove(entry: IDatabaseEntry): void {
        setRemovingEntry(entry);
        setConfirmRemoveOpen(true);
    }

    //
    // Confirms removal of the pending entry.
    //
    async function handleConfirmRemove(): Promise<void> {
        if (removingEntry) {
            await platform.removeDatabaseEntry(removingEntry.path);
            setRemovingEntry(undefined);
        }
        setConfirmRemoveOpen(false);
        await loadData();
    }

    //
    // Opens the selected database and navigates to the home page.
    //
    async function handleOpen(entry: IDatabaseEntry): Promise<void> {
        await openDatabase(entry.path);
        navigate('/');
    }

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
    // Handles a newly created secret from the quick-create dialog and auto-selects it.
    //
    async function handleQuickCreateSave(newSecret: ISharedSecretEntry): Promise<void> {
        setQuickCreateType(undefined);
        await loadData();
        if (newSecret.type === 's3-credentials') {
            setForm(prev => ({ ...prev, s3Key: newSecret.id }));
        }
        else if (newSecret.type === 'encryption-key') {
            setForm(prev => ({ ...prev, encryptionKey: newSecret.id }));
        }
        else {
            setForm(prev => ({ ...prev, geocodingKey: newSecret.id }));
        }
    }

    //
    // Renders a secret selector row with a dropdown and a "+ New" button.
    //
    function renderSecretSelector(
        label: string,
        options: ISharedSecretEntry[],
        selectedId: string | undefined,
        onChange: (id: string | undefined) => void,
        secretType: string
    ): React.ReactNode {
        return (
            <FormControl sx={{ mb: 1 }}>
                <FormLabel>{label}</FormLabel>
                <Box sx={{ display: 'flex', gap: 1 }}>
                    <Select
                        sx={{ flexGrow: 1 }}
                        value={selectedId ?? ''}
                        onChange={(_event, value) => onChange(value as string || undefined)}
                        placeholder="None"
                    >
                        <Option value="">None</Option>
                        {options.map(secret => (
                            <Option key={secret.id} value={secret.id}>{secret.name}</Option>
                        ))}
                    </Select>
                    <Button
                        variant="outlined"
                        size="sm"
                        onClick={() => setQuickCreateType(secretType)}
                    >
                        + New
                    </Button>
                </Box>
            </FormControl>
        );
    }

    return (
        <Box sx={{ p: 3 }}>
            <Box sx={{ display: 'flex', alignItems: 'center', mb: 2 }}>
                <Typography level="h3">Manage Databases</Typography>
                <Box sx={{ flexGrow: 1 }} />
                <IconButton
                    variant="outlined"
                    sx={{ mr: 1 }}
                    disabled={refreshing}
                    onClick={() => handleRefresh().catch(err => console.error('Failed to refresh data:', err))}
                >
                    <Refresh
                        sx={refreshing ? {
                            animation: 'spin 0.8s linear infinite',
                            '@keyframes spin': {
                                from: { transform: 'rotate(0deg)' },
                                to: { transform: 'rotate(360deg)' },
                            },
                        } : undefined}
                    />
                </IconButton>
                <Button
                    variant="outlined"
                    sx={{ mr: 1 }}
                    onClick={() => setCreateModalOpen(true)}
                >
                    New database
                </Button>
                <Button
                    variant="outlined"
                    onClick={() => setAddModalOpen(true)}
                >
                    Add database
                </Button>
            </Box>

            <Table>
                <thead>
                    <tr>
                        <th>Name</th>
                        <th>Description</th>
                        <th>Path</th>
                        <th>Origin</th>
                        <th style={{ width: '112px', whiteSpace: 'nowrap' }}>Actions</th>
                    </tr>
                </thead>
                <tbody>
                    {databases.map(entry => (
                        <tr key={entry.path}>
                            <td>{entry.name}</td>
                            <td>{entry.description}</td>
                            <td>{entry.path}</td>
                            <td>{entry.origin ?? ''}</td>
                            <td style={{ whiteSpace: 'nowrap' }}>
                                <IconButton
                                    size="sm"
                                    variant="plain"
                                    onClick={() => handleOpen(entry).catch(err => console.error('Open database error:', err))}
                                >
                                    <FolderOpen fontSize="small" />
                                </IconButton>
                                <IconButton
                                    size="sm"
                                    variant="plain"
                                    onClick={() => openEditDialog(entry)}
                                >
                                    <Edit fontSize="small" />
                                </IconButton>
                                <IconButton
                                    size="sm"
                                    variant="plain"
                                    color="danger"
                                    onClick={() => promptRemove(entry)}
                                >
                                    <Delete fontSize="small" />
                                </IconButton>
                            </td>
                        </tr>
                    ))}
                </tbody>
            </Table>

            {/* Add / Edit dialog */}
            <Modal open={dialogOpen} onClose={() => setDialogOpen(false)}>
                <ModalDialog sx={{ minWidth: 500, maxWidth: 700, overflowY: 'auto' }}>
                    <ModalClose />
                    <DialogTitle>{editingEntry ? 'Edit Database' : 'Add Database'}</DialogTitle>
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
                            <FormLabel>Path</FormLabel>
                            <Box sx={{ display: 'flex', gap: 1 }}>
                                <Input
                                    sx={{ flexGrow: 1 }}
                                    value={form.path}
                                    onChange={event => setForm(prev => ({ ...prev, path: event.target.value }))}
                                />
                                <Button variant="outlined" onClick={() => handleBrowse().catch(err => console.error('Browse error:', err))}>
                                    Browse
                                </Button>
                            </Box>
                        </FormControl>

                        {renderSecretSelector(
                            'S3 Credentials',
                            s3Secrets,
                            form.s3Key,
                            id => setForm(prev => ({ ...prev, s3Key: id })),
                            's3-credentials'
                        )}

                        {renderSecretSelector(
                            'Encryption Key',
                            encryptionSecrets,
                            form.encryptionKey,
                            id => setForm(prev => ({ ...prev, encryptionKey: id })),
                            'encryption-key'
                        )}

                        {renderSecretSelector(
                            'Geocoding API Key',
                            geocodingSecrets,
                            form.geocodingKey,
                            id => setForm(prev => ({ ...prev, geocodingKey: id })),
                            'api-key'
                        )}
                    </DialogContent>
                    <DialogActions>
                        <Button variant="plain" onClick={() => setDialogOpen(false)}>Cancel</Button>
                        <Button onClick={() => handleSave().catch(err => console.error('Save error:', err))}>Save</Button>
                    </DialogActions>
                </ModalDialog>
            </Modal>

            {/* Remove confirmation dialog */}
            <Modal open={confirmRemoveOpen} onClose={() => setConfirmRemoveOpen(false)}>
                <ModalDialog>
                    <DialogTitle>Remove Database Entry</DialogTitle>
                    <DialogContent>
                        <Typography>
                            Remove <strong>{removingEntry?.name || removingEntry?.path}</strong> from the list?
                        </Typography>
                        <Typography level="body-sm" sx={{ mt: 1 }}>
                            This only removes the entry from Photosphere's database list.
                            No files on disk will be deleted. Shared secrets are not affected.
                        </Typography>
                    </DialogContent>
                    <DialogActions>
                        <Button variant="plain" onClick={() => setConfirmRemoveOpen(false)}>Cancel</Button>
                        <Button
                            color="danger"
                            onClick={() => handleConfirmRemove().catch(err => console.error('Remove error:', err))}
                        >
                            Remove
                        </Button>
                    </DialogActions>
                </ModalDialog>
            </Modal>

            {/* Quick-create secret dialog */}
            {quickCreateType !== undefined && (
                <CreateSecretDialog
                    open={true}
                    secretType={quickCreateType}
                    defaultName={form.name || form.path}
                    onClose={() => setQuickCreateType(undefined)}
                    onSave={newSecret => handleQuickCreateSave(newSecret).catch(err => console.error('Quick-create error:', err))}
                />
            )}

            <CreateDatabaseModal
                open={createModalOpen}
                onClose={() => {
                    setCreateModalOpen(false);
                    loadData().catch(err => console.error('Failed to reload data:', err));
                }}
            />

            <AddDatabaseModal
                open={addModalOpen}
                onClose={() => {
                    setAddModalOpen(false);
                    loadData().catch(err => console.error('Failed to reload data:', err));
                }}
            />
        </Box>
    );
}
