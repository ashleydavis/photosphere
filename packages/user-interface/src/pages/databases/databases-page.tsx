import React, { useEffect, useState } from 'react';
import { log } from 'utils';
import Box from '@mui/material/Box';
import Typography from '@mui/material/Typography';
import Table from '@mui/material/Table';
import TableHead from '@mui/material/TableHead';
import TableBody from '@mui/material/TableBody';
import TableRow from '@mui/material/TableRow';
import TableCell from '@mui/material/TableCell';
import IconButton from '@mui/material/IconButton';
import { Edit, Delete, FolderOpen, IosShare, Visibility, FileCopy, Add, NoteAdd, Download, Storage, Star, CloudSync } from '@mui/icons-material';
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
import { ConsolidateDatabaseDialog } from '../../components/consolidate-database-dialog';
import { useConfigStore } from '../../context/config-store-context';
import { getDefaultDatabasePath, setDefaultDatabasePath } from '../../lib/auto-import-config';
import Chip from '@mui/material/Chip';
import { LIST_TABLE_SX } from '../../lib/list-table-styles';

//
// Full CRUD management page for configured database entries.
//
export function DatabasesPage() {
    const platform = usePlatform();
    const config = useConfigStore();
    const { dbs: databases, secrets, refresh } = useApp();
    const { openDatabase } = useAssetDatabase();
    const navigate = useNavigate();

    // On a mobile-width screen there is no room for the secondary columns (description, path,
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

    // The database entry being connected to a remote (undefined when the dialog is closed).
    const [consolidatingEntry, setConsolidatingEntry] = useState<IDatabaseEntry | undefined>(undefined);

    // The path of the database automatic import writes to, or undefined when none has been chosen.
    const [defaultDatabasePath, setDefaultDatabasePathState] = useState<string | undefined>(undefined);

    useEffect(() => {
        getDefaultDatabasePath(config)
            .then(path => setDefaultDatabasePathState(path))
            .catch(error => log.exception('Failed to read the default database', error as Error));
    }, [config, databases]);

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
    // Makes this the database automatic import writes to.
    //
    // Exactly one database may hold it, which is what writing a single path achieves: whichever was
    // the default before simply stops being it.
    //
    async function makeDefault(entry: IDatabaseEntry): Promise<void> {
        await setDefaultDatabasePath(config, entry.path);
        setDefaultDatabasePathState(entry.path);
        log.event('Default database set');
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
                label: 'Set as default',
                icon: <Star fontSize="small" />,
                dataId: 'set-default-database-button',
                onClick: () => {
                    makeDefault(entry).catch(error => log.exception('Failed to set the default database', error as Error));
                },
            },
            {
                label: 'Consolidate into remote',
                icon: <CloudSync fontSize="small" />,
                dataId: 'consolidate-database-button',
                onClick: () => { log.info('Consolidate into remote dialog opened'); setConsolidatingEntry(entry); },
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
        <Box
            sx={{
                //
                // The page fills the area under the navbar and scrolls itself, as the other
                // information pages do. Its side padding grows to hold the content in a centred
                // column no wider than 30 * --space-8, so the scrollbar stays at the window's edge.
                //
                height: '100%',
                overflowY: 'auto',
                padding: isMobile ? 'var(--space-4) var(--space-4) var(--space-8)' : 'var(--space-6) var(--space-6) var(--space-8)',
                paddingInline: `max(${isMobile ? 'var(--space-4)' : 'var(--space-6)'}, calc((100% - var(--space-8) * 30) / 2))`,
            }}
            >
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
                        display: 'flex',
                        flexDirection: 'column',
                        alignItems: 'center',
                        gap: 'var(--space-2)',
                        textAlign: 'center',
                        padding: 'var(--space-8) var(--space-4)',
                        background: 'var(--color-panel)',
                        border: '1px solid var(--color-border)',
                        borderRadius: 'var(--radius-md)',
                        boxShadow: 'var(--shadow-raised)',
                    }}
                    >
                    <Box
                        aria-hidden={true}
                        sx={{
                            display: 'flex',
                            alignItems: 'center',
                            justifyContent: 'center',
                            width: 'calc(var(--space-8) * 2)',
                            height: 'calc(var(--space-8) * 2)',
                            borderRadius: 'var(--radius-full)',
                            background: 'var(--empty-icon-bg)',
                            color: 'var(--color-empty-icon)',
                            fontSize: 'var(--space-8)',
                        }}
                        >
                        <Storage fontSize="inherit" />
                    </Box>
                    <Typography
                        variant="subtitle1"
                        sx={{
                            fontSize: 'var(--text-lg)',
                            fontWeight: 'var(--weight-bold)',
                        }}
                        >
                        No databases yet
                    </Typography>
                    <Typography
                        variant="body2"
                        sx={{
                            color: 'var(--color-text-muted)',
                            fontSize: 'var(--text-sm)',
                        }}
                        >
                        Create a new database, add an existing one, or receive one from another device.
                    </Typography>
                </Box>
            }

            {/* A mobile gets a list of cards: the name has the whole width, the supporting detail is
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
                            monoTitle={false}
                            subtitleChip={false}
                            />
                    ))}
                </Box>
            }

            {databases.length > 0 && !isMobile
                && <Box
                    sx={{
                        background: 'var(--list-table-bg)',
                        border: '1px solid var(--list-table-border-color)',
                        borderRadius: 'var(--radius-md)',
                        boxShadow: 'var(--list-table-shadow)',
                        overflow: 'hidden',
                    }}
                    >
                    <Table sx={LIST_TABLE_SX}>
                        <TableHead>
                            <TableRow>
                                <TableCell>Name</TableCell>
                                <TableCell>Description</TableCell>
                                <TableCell>Path</TableCell>
                                <TableCell>Origin</TableCell>
                                <TableCell
                                    sx={{
                                        whiteSpace: 'nowrap',
                                    }}
                                    >
                                    Actions
                                </TableCell>
                            </TableRow>
                        </TableHead>
                        <TableBody>
                            {databases.map((entry, entryIndex) => (
                                <TableRow key={entry.name}>
                                    <TableCell>
                                        <Box
                                            sx={{
                                                display: 'flex',
                                                alignItems: 'center',
                                                gap: 'var(--space-3)',
                                            }}
                                            >
                                            <Box
                                                aria-hidden={true}
                                                sx={{
                                                    display: 'flex',
                                                    alignItems: 'center',
                                                    justifyContent: 'center',
                                                    flex: 'none',
                                                    width: 'calc(var(--space-8) + var(--space-2))',
                                                    height: 'calc(var(--space-8) + var(--space-2))',
                                                    background: 'var(--color-chip-bg)',
                                                    color: 'var(--color-accent)',
                                                    border: '1px solid var(--color-chip-border)',
                                                    borderRadius: 'var(--radius-md)',
                                                    fontSize: 'var(--icon-lg)',
                                                }}
                                                >
                                                <Storage fontSize="inherit" />
                                            </Box>
                                            <Box
                                                data-id={`database-row-name-${entry.name}`}
                                                sx={{
                                                    display: 'flex',
                                                    flexWrap: 'wrap',
                                                    alignItems: 'center',
                                                    gap: 'var(--space-1) var(--space-2)',
                                                    fontWeight: 'var(--weight-bold)',
                                                }}
                                                >
                                                {entry.name}
                                                {entry.path === defaultDatabasePath
                                                    && <Chip
                                                        size="small"
                                                        icon={<Star />}
                                                        data-id={`database-default-badge-${entryIndex}`}
                                                        label="Default"
                                                        sx={{
                                                            minHeight: 'var(--space-6)',
                                                            fontSize: 'var(--text-xs)',
                                                            fontWeight: 'var(--weight-bold)',
                                                            '& .MuiChip-icon': {
                                                                fontSize: 'var(--icon-sm)',
                                                                color: 'var(--color-chip-text)',
                                                                marginLeft: 'var(--space-2)',
                                                            },
                                                        }}
                                                        />
                                                }
                                            </Box>
                                        </Box>
                                    </TableCell>
                                    <TableCell className="list-table-muted">{entry.description}</TableCell>
                                    <TableCell className="list-table-mono">{entry.path}</TableCell>
                                    <TableCell className="list-table-muted">{entry.origin ?? ''}</TableCell>
                                    <TableCell
                                        sx={{
                                            whiteSpace: 'nowrap',
                                        }}
                                        >
                                        <IconButton
                                            data-id="view-database-button"
                                            size="small"
                                            title="View database"
                                            onClick={() => { log.info('View database dialog opened'); setViewingEntry(entry); }}
                                        >
                                            <Visibility fontSize="small" />
                                        </IconButton>
                                        <IconButton
                                            data-id="open-database-button"
                                            size="small"
                                            title="Open database"
                                            onClick={() => handleOpen(entry).catch(err => log.exception('Open database error:', err as Error))}
                                        >
                                            <FolderOpen fontSize="small" />
                                        </IconButton>
                                        <IconButton
                                            data-id="share-database-button"
                                            size="small"
                                            title="Share database"
                                            onClick={() => setSharingEntry(entry)}
                                        >
                                            <IosShare fontSize="small" />
                                        </IconButton>
                                        <IconButton
                                            data-id="replicate-database-button"
                                            size="small"
                                            title="Replicate database"
                                            onClick={() => { log.info('Replicate database dialog opened'); setReplicatingEntry(entry); }}
                                        >
                                            <FileCopy fontSize="small" />
                                        </IconButton>
                                        <IconButton
                                            data-id="set-default-database-button"
                                            size="small"
                                            title="Set as the database automatic import writes to"
                                            onClick={() => {
                                                makeDefault(entry).catch(error => log.exception('Failed to set the default database', error as Error));
                                            }}
                                        >
                                            <Star fontSize="small" />
                                        </IconButton>
                                        <IconButton
                                            data-id="consolidate-database-button"
                                            size="small"
                                            title="Consolidate into remote"
                                            onClick={() => { log.info('Consolidate into remote dialog opened'); setConsolidatingEntry(entry); }}
                                        >
                                            <CloudSync fontSize="small" />
                                        </IconButton>
                                        <IconButton
                                            data-id="edit-database-button"
                                            size="small"
                                            title="Edit database"
                                            onClick={() => openEditDialog(entry)}
                                        >
                                            <Edit fontSize="small" />
                                        </IconButton>
                                        <IconButton
                                            size="small"
                                            title="Remove database"
                                            onClick={() => promptRemove(entry)}
                                            sx={{
                                                color: 'var(--color-danger-button-text)',
                                                borderColor: 'var(--color-danger-button-border)',
                                                backgroundColor: 'var(--color-danger-button-fill)',
                                                '&:hover': {
                                                    color: 'var(--color-danger-button-text)',
                                                    backgroundColor: 'var(--color-danger-button-fill)',
                                                    boxShadow: 'inset 0 0 0 1px var(--color-danger-button-border)',
                                                },
                                            }}
                                        >
                                            <Delete fontSize="small" />
                                        </IconButton>
                                    </TableCell>
                                </TableRow>
                            ))}
                        </TableBody>
                    </Table>
                </Box>
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

            {consolidatingEntry !== undefined && (
                <ConsolidateDatabaseDialog
                    open={consolidatingEntry !== undefined}
                    entry={consolidatingEntry!}
                    onClose={() => {
                        setConsolidatingEntry(undefined);
                        refresh().catch(error => log.exception('Failed to refresh after connecting', error as Error));
                    }}
                />
            )}
        </Box>
    );
}
