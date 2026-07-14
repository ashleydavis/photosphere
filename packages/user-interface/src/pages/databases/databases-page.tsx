import React, { useEffect, useState } from 'react';
import { log } from 'utils';
import Box from '@mui/joy/Box';
import Typography from '@mui/joy/Typography';
import Button from '@mui/joy/Button';
import Table from '@mui/joy/Table';
import IconButton from '@mui/joy/IconButton';
import { Edit, Delete, Refresh, FolderOpen, IosShare, Visibility, FileCopy, Add, NoteAdd, Download, Storage } from '@mui/icons-material';
import { useNavigate } from 'react-router-dom';
import { usePlatform, type IDatabaseEntry } from '../../context/platform-context';
import { useApp } from '../../context/app-context';
import { useAssetDatabase } from '../../context/asset-database-source';
import { useIsMobile } from '../../lib/use-is-mobile';
import { MobilePageHeader } from '../../components/mobile-page-header';
import { EntityCard, type IEntityCardAction } from '../../components/entity-card';
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

    // On a phone-width screen there is no room for the secondary columns (description, path,
    // origin), so the table shows just the name and the actions. The full detail is still one tap
    // away in the view-database dialog.
    const isMobile = useIsMobile();

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

    // Re-read the databases/secrets lists when the page mounts, so state seeded or changed outside
    // this provider instance (e.g. mobile test setup) is reflected when the page is entered.
    useEffect(() => {
        refresh().catch(err => log.exception('Failed to refresh on databases page mount:', err as Error));
    }, []);

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

    //
    // The actions offered for a single database, in the order they appear in a card's ⋮ menu.
    // Opening the database is the card's tap action, so it is not repeated here on mobile.
    //
    function databaseActions(entry: IDatabaseEntry): IEntityCardAction[] {
        return [
            {
                label: 'View details',
                icon: <Visibility fontSize="small" />,
                dataId: 'view-database-button',
                onClick: () => { log.info('View database dialog opened'); setViewingEntry(entry); },
            },
            {
                label: 'Share',
                icon: <IosShare fontSize="small" />,
                dataId: 'share-database-button',
                onClick: () => setSharingEntry(entry),
            },
            {
                label: 'Replicate',
                icon: <FileCopy fontSize="small" />,
                dataId: 'replicate-database-button',
                onClick: () => { log.info('Replicate database dialog opened'); setReplicatingEntry(entry); },
            },
            {
                label: 'Edit',
                icon: <Edit fontSize="small" />,
                dataId: 'edit-database-button',
                onClick: () => openEditDialog(entry),
            },
            {
                label: 'Remove',
                icon: <Delete fontSize="small" />,
                danger: true,
                onClick: () => promptRemove(entry),
            },
        ];
    }

    return (
        <Box sx={{ p: isMobile ? 2 : 3 }}>
            <MobilePageHeader
                title="Manage Databases"
                subtitle={databases.length === 1 ? '1 database' : `${databases.length} databases`}
                refreshing={refreshing}
                onRefresh={() => handleRefresh().catch(err => log.exception('Failed to refresh data:', err as Error))}
                primaryAction={{
                    label: 'New database',
                    icon: <Add />,
                    onClick: () => setCreateModalOpen(true),
                }}
                secondaryActions={[
                    {
                        label: 'Add database',
                        icon: <NoteAdd fontSize="small" />,
                        dataId: 'add-database-button',
                        onClick: () => setAddModalOpen(true),
                    },
                    {
                        label: 'Receive database',
                        icon: <Download fontSize="small" />,
                        dataId: 'receive-database-button',
                        onClick: () => setReceiveDbDialogOpen(true),
                    },
                ]}
                />

            {databases.length === 0
                && <Box
                    sx={{
                        textAlign: 'center',
                        py: 6,
                        px: 2,
                        borderRadius: 'lg',
                        backgroundColor: 'background.level1',
                    }}
                    >
                    <Storage sx={{ fontSize: 48, color: 'text.tertiary', mb: 1 }} />
                    <Typography level="title-md" sx={{ mb: 0.5 }}>No databases yet</Typography>
                    <Typography level="body-sm" sx={{ color: 'text.tertiary' }}>
                        Create a new database, add an existing one, or receive one from another device.
                    </Typography>
                </Box>
            }

            {/* A phone gets a list of cards: the name has the whole width, the supporting detail is
                stacked under it, and the six per-row actions live in the card's ⋮ menu. The table is
                kept for wide screens, where the columns fit and are worth having. */}
            {databases.length > 0 && isMobile
                && <Box>
                    {databases.map(entry => (
                        <EntityCard
                            key={entry.name}
                            title={entry.name}
                            titleDataId={`database-row-name-${entry.name}`}
                            subtitle={entry.description}
                            detail={entry.path}
                            icon={<Storage />}
                            onClick={() => handleOpen(entry).catch(err => log.exception('Open database error:', err as Error))}
                            actions={databaseActions(entry)}
                            />
                    ))}
                </Box>
            }

            {databases.length > 0 && !isMobile
                && <Table>
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
            }

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
