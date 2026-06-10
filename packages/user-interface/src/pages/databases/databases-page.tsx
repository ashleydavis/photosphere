import React, { useEffect, useState } from 'react';
import { log } from 'utils';
import Box from '@mui/joy/Box';
import Typography from '@mui/joy/Typography';
import Button from '@mui/joy/Button';
import Table from '@mui/joy/Table';
import IconButton from '@mui/joy/IconButton';
import { Edit, Delete, Refresh, FolderOpen, IosShare, Visibility, FileCopy, Add } from '@mui/icons-material';
import { useNavigate } from 'react-router-dom';
import { usePlatform, type IDatabaseEntry } from '../../context/platform-context';
import { useApp } from '../../context/app-context';
import { useAssetDatabase } from '../../context/asset-database-source';
import { CreateDatabaseModal } from '../../components/create-database-modal';
import { AddDatabaseModal } from '../../components/add-database-modal';
import { EditDatabaseModal } from '../../components/edit-database-modal';
import { RemoveDatabaseDialog } from '../../components/remove-database-dialog';
import { ShareDatabaseDialog } from '../../components/share-database-dialog';
import { ReceiveDatabaseDialog } from '../../components/receive-database-dialog';
import { ViewDatabaseDialog } from '../../components/view-database-dialog';
import { ReplicateDatabaseDialog } from '../../components/replicate-database-dialog';

//
// Full CRUD management page for configured database entries.
//
export function DatabasesPage() {
    const platform = usePlatform();
    const { dbs: databases, secrets, refresh } = useApp();
    const { openDatabase } = useAssetDatabase();
    const navigate = useNavigate();

    // Shared secrets grouped by type, derived from the context's combined list.
    const s3Secrets = secrets.filter(secret => secret.type === 's3-credentials');
    const encryptionSecrets = secrets.filter(secret => secret.type === 'encryption-key');
    const geocodingSecrets = secrets.filter(secret => secret.type === 'api-key');

    // Whether the create-database modal is open.
    const [createModalOpen, setCreateModalOpen] = useState(false);

    // Whether the add-database modal is open.
    const [addModalOpen, setAddModalOpen] = useState(false);

    // Whether the edit dialog is open.
    const [dialogOpen, setDialogOpen] = useState(false);

    // Entry being edited (undefined when adding new).
    const [editingEntry, setEditingEntry] = useState<IDatabaseEntry | undefined>(undefined);

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

    useEffect(() => {
        log.event('Databases page loaded');
    }, [databases, secrets]);

    //
    // Reloads data with a minimum delay so the spin animation is visible.
    //
    async function handleRefresh(): Promise<void> {
        setRefreshing(true);
        await Promise.all([
            refresh(),
            new Promise(resolve => setTimeout(resolve, 500)),
        ]);
        setRefreshing(false);
    }

    //
    // Opens the edit dialog for the given entry.
    //
    function openEditDialog(entry: IDatabaseEntry): void {
        setEditingEntry(entry);
        setDialogOpen(true);
    }

    //
    // Opens the remove confirmation dialog for the given entry.
    //
    function promptRemove(entry: IDatabaseEntry): void {
        setRemovingEntry(entry);
        setConfirmRemoveOpen(true);
    }

    //
    // Opens the selected database and navigates to the home page.
    //
    async function handleOpen(entry: IDatabaseEntry): Promise<void> {
        await openDatabase(entry.path);
        navigate('/');
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
                    startDecorator={<Add />}
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
                    {databases.length === 0 && (
                        <tr>
                            <td colSpan={5}>
                                <p className="pt-2 text-gray-500">No databases yet. Click New database to create one, Add database to register an existing one, or Receive database to import one from another device.</p>
                            </td>
                        </tr>
                    )}
                    {databases.map(entry => (
                        <tr key={entry.name}>
                            <td data-id={`database-row-name-${entry.name}`}>{entry.name}</td>
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
                                    data-id="edit-database-button"
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

            <EditDatabaseModal
                open={dialogOpen}
                entry={editingEntry}
                databases={databases}
                s3Secrets={s3Secrets}
                encryptionSecrets={encryptionSecrets}
                geocodingSecrets={geocodingSecrets}
                onClose={() => {
                    setDialogOpen(false);
                    setEditingEntry(undefined);
                }}
            />

            <RemoveDatabaseDialog
                open={confirmRemoveOpen}
                entry={removingEntry}
                onClose={() => {
                    setConfirmRemoveOpen(false);
                    setRemovingEntry(undefined);
                }}
            />

            <CreateDatabaseModal
                open={createModalOpen}
                onClose={() => setCreateModalOpen(false)}
            />

            <AddDatabaseModal
                open={addModalOpen}
                onClose={() => setAddModalOpen(false)}
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
                onClose={() => setReceiveDbDialogOpen(false)}
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
                    onClose={() => setReplicatingEntry(undefined)}
                />
            )}
        </Box>
    );
}
