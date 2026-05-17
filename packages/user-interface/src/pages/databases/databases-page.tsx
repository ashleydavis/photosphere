import React, { useEffect, useState } from 'react';
import { log } from 'utils';
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
import { Edit, Delete, Refresh, FolderOpen, IosShare, Visibility, FileCopy } from '@mui/icons-material';
import { useNavigate } from 'react-router-dom';
import { usePlatform, type IDatabaseEntry, type ISharedSecretEntry } from '../../context/platform-context';
import { useAssetDatabase } from '../../context/asset-database-source';
import { ConfigureSecretsModal, type IDatabaseSecretsSelection } from '../../components/configure-secrets-modal';
import { CreateDatabaseModal } from '../../components/create-database-modal';
import { AddDatabaseModal } from '../../components/add-database-modal';
import { ShareDatabaseDialog } from '../../components/share-database-dialog';
import { ReceiveDatabaseDialog } from '../../components/receive-database-dialog';
import { ViewDatabaseDialog } from '../../components/view-database-dialog';
import { ReplicateDatabaseDialog } from '../../components/replicate-database-dialog';

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

    // Whether a refresh is in progress (drives the spin animation).
    const [refreshing, setRefreshing] = useState(false);

    // The database entry being shared via LAN share (undefined when no share is in progress).
    const [sharingEntry, setSharingEntry] = useState<IDatabaseEntry | undefined>(undefined);

    // Whether the receive-database dialog is open.
    const [receiveDbDialogOpen, setReceiveDbDialogOpen] = useState(false);

    // The database entry currently being viewed (undefined when dialog is closed).
    const [viewingEntry, setViewingEntry] = useState<IDatabaseEntry | undefined>(undefined);

    // The database entry currently being replicated (undefined when the dialog is closed).
    const [replicatingEntry, setReplicatingEntry] = useState<IDatabaseEntry | undefined>(undefined);

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
        log.event('Databases page loaded');
    }

    useEffect(() => {
        loadData().catch(err => log.exception('Failed to load data:', err as Error));
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
        setNameError(undefined);
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
        setNameError(undefined);
        setDialogOpen(true);
    }

    // Inline name-conflict error shown under the Name field in the add/edit dialog.
    const [nameError, setNameError] = useState<string | undefined>(undefined);

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

        const entryData: Omit<IDatabaseEntry, 'id'> = {
            name: trimmedName,
            description: form.description,
            path: form.path,
            s3Key: form.s3Key,
            encryptionKey: form.encryptionKey,
            geocodingKey: form.geocodingKey,
        };

        // Detect name collisions before submit so the user gets inline feedback rather
        // than an unhandled rejection from the storage-layer invariant.
        const isRenameToSelf = editingEntry && editingEntry.name.toLowerCase() === trimmedName.toLowerCase();
        if (!isRenameToSelf) {
            const collision = databases.find(existing => existing.name.toLowerCase() === trimmedName.toLowerCase());
            if (collision && (!editingEntry || collision.name.toLowerCase() !== editingEntry.name.toLowerCase())) {
                setNameError(`A database named "${trimmedName}" already exists.`);
                return;
            }
        }

        if (editingEntry) {
            await platform.updateDatabase(editingEntry.name, { ...editingEntry, ...entryData });
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
            await platform.removeDatabaseEntry(removingEntry.name);
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
    // Whether the Configure Secrets modal is open over the Add/Edit dialog.
    //
    const [secretsModalOpen, setSecretsModalOpen] = useState(false);

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

    return (
        <Box sx={{ p: 3 }}>
            <Box sx={{ display: 'flex', alignItems: 'center', mb: 2 }}>
                <Typography level="h3">Manage Databases</Typography>
                <Box sx={{ flexGrow: 1 }} />
                <IconButton
                    variant="outlined"
                    sx={{ mr: 1 }}
                    disabled={refreshing}
                    title="Refresh"
                    onClick={() => handleRefresh().catch(err => log.exception('Failed to refresh data:', err as Error))}
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
                    data-id="add-database-button"
                    variant="outlined"
                    sx={{ mr: 1 }}
                    onClick={() => setAddModalOpen(true)}
                >
                    Add database
                </Button>
                <Button
                    data-id="receive-database-button"
                    variant="outlined"
                    onClick={() => setReceiveDbDialogOpen(true)}
                >
                    Receive database
                </Button>
            </Box>

            <Table>
                <thead>
                    <tr>
                        <th>Name</th>
                        <th>Description</th>
                        <th>Path</th>
                        <th>Origin</th>
                        <th style={{ width: '170px', whiteSpace: 'nowrap' }}>Actions</th>
                    </tr>
                </thead>
                <tbody>
                    {databases.map(entry => (
                        <tr key={entry.name}>
                            <td>{entry.name}</td>
                            <td>{entry.description}</td>
                            <td>{entry.path}</td>
                            <td>{entry.origin ?? ''}</td>
                            <td style={{ whiteSpace: 'nowrap' }}>
                                <IconButton
                                    data-id="view-database-button"
                                    size="sm"
                                    variant="plain"
                                    title="View database"
                                    onClick={() => { log.info('View database dialog opened'); setViewingEntry(entry); }}
                                >
                                    <Visibility fontSize="small" />
                                </IconButton>
                                <IconButton
                                    data-id="open-database-button"
                                    size="sm"
                                    variant="plain"
                                    title="Open database"
                                    onClick={() => handleOpen(entry).catch(err => log.exception('Open database error:', err as Error))}
                                >
                                    <FolderOpen fontSize="small" />
                                </IconButton>
                                <IconButton
                                    data-id="share-database-button"
                                    size="sm"
                                    variant="plain"
                                    title="Share database"
                                    onClick={() => setSharingEntry(entry)}
                                >
                                    <IosShare fontSize="small" />
                                </IconButton>
                                <IconButton
                                    data-id="replicate-database-button"
                                    size="sm"
                                    variant="plain"
                                    title="Replicate database"
                                    onClick={() => { log.info('Replicate database dialog opened'); setReplicatingEntry(entry); }}
                                >
                                    <FileCopy fontSize="small" />
                                </IconButton>
                                <IconButton
                                    size="sm"
                                    variant="plain"
                                    title="Edit database"
                                    onClick={() => openEditDialog(entry)}
                                >
                                    <Edit fontSize="small" />
                                </IconButton>
                                <IconButton
                                    size="sm"
                                    variant="plain"
                                    color="danger"
                                    title="Remove database"
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

                        <FormControl sx={{ mb: 2 }}>
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
                        <Button variant="plain" onClick={() => setDialogOpen(false)}>Cancel</Button>
                        <Button onClick={() => handleSave().catch(err => log.exception('Save error:', err as Error))}>Save</Button>
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
                            onClick={() => handleConfirmRemove().catch(err => log.exception('Remove error:', err as Error))}
                        >
                            Remove
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
                onSecretCreated={() => loadData()}
                quickCreateDefaultName={form.name || form.path}
            />

            <CreateDatabaseModal
                open={createModalOpen}
                onClose={() => {
                    setCreateModalOpen(false);
                    loadData().catch(err => log.exception('Failed to reload data:', err as Error));
                }}
            />

            <AddDatabaseModal
                open={addModalOpen}
                onClose={() => {
                    setAddModalOpen(false);
                    loadData().catch(err => log.exception('Failed to reload data:', err as Error));
                }}
            />

            {sharingEntry && (
                <ShareDatabaseDialog
                    open={sharingEntry !== undefined}
                    entry={sharingEntry}
                    onClose={() => setSharingEntry(undefined)}
                />
            )}

            <ReceiveDatabaseDialog
                open={receiveDbDialogOpen}
                onClose={() => {
                    setReceiveDbDialogOpen(false);
                    loadData().catch(err => log.exception('Failed to reload data:', err as Error));
                }}
            />

            {viewingEntry !== undefined && (
                <ViewDatabaseDialog
                    open={viewingEntry !== undefined}
                    entry={viewingEntry!}
                    allSecrets={[...s3Secrets, ...encryptionSecrets, ...geocodingSecrets]}
                    onClose={() => setViewingEntry(undefined)}
                    getSecretValue={platform.getSecretValue}
                />
            )}

            {replicatingEntry !== undefined && (
                <ReplicateDatabaseDialog
                    open={replicatingEntry !== undefined}
                    sourceEntry={replicatingEntry!}
                    encryptionSecrets={encryptionSecrets}
                    s3Secrets={s3Secrets}
                    geocodingSecrets={geocodingSecrets}
                    onSecretCreated={() => loadData()}
                    onClose={() => {
                        setReplicatingEntry(undefined);
                        loadData().catch(err => log.exception('Failed to reload data:', err as Error));
                    }}
                />
            )}
        </Box>
    );
}
