import React, { useEffect, useState } from 'react';
import { log } from 'utils';
import Box from '@mui/material/Box';
import Typography from '@mui/material/Typography';
import Button from '@mui/material/Button';
import Table from '@mui/material/Table';
import TableHead from '@mui/material/TableHead';
import TableBody from '@mui/material/TableBody';
import TableRow from '@mui/material/TableRow';
import TableCell from '@mui/material/TableCell';
import IconButton from '@mui/material/IconButton';
import { ResponsiveDialog } from '../../components/responsive-dialog';
import DialogTitle from '@mui/material/DialogTitle';
import DialogContent from '@mui/material/DialogContent';
import DialogActions from '@mui/material/DialogActions';
import OutlinedInput from '@mui/material/OutlinedInput';
import FormControl from '@mui/material/FormControl';
import FormLabel from '@mui/material/FormLabel';
import Select from '@mui/material/Select';
import MenuItem from '@mui/material/MenuItem';
import { Edit, Delete, Add, IosShare, Visibility, Download, Key, Close } from '@mui/icons-material';
import { usePlatform, type ISharedSecretEntry, type IDatabaseEntry } from '../../context/platform-context';
import { useApp } from '../../context/app-context';
import { useIsMobile } from '../../lib/use-is-mobile';
import { MobilePageHeader } from '../../components/mobile-page-header';
import { EntityCard, type IEntityCardAction } from '../../components/entity-card';
import { ShareSecretDialog } from '../../components/share-secret-dialog';
import { ReceiveSecretDialog } from '../../components/receive-secret-dialog';
import { ViewSecretDialog } from '../../components/view-secret-dialog';
import { applyValueJson, buildValueJson, emptyFormState, type ISecretFormState } from '../../lib/secrets-form';
import { createDialogKeyHandler } from '../../lib/dialog-keys';
import { DialogIconBadge } from '../../components/dialog-icon-badge';
import Chip from '@mui/material/Chip';
import { LIST_TABLE_SX } from '../../lib/list-table-styles';

//
// The supported secret type identifiers.
//
const SECRET_TYPES = ['s3-credentials', 'encryption-key', 'api-key'] as const;

//
// Props for a Select's display element, the part that shows the chosen value. Material types
// SelectDisplayProps as plain div attributes, which have no `data-id`.
//
interface ISelectDisplayProps extends React.HTMLAttributes<HTMLDivElement> {
    //
    // Identifies the select to the smoke tests, which click it and read the chosen value from it.
    //
    'data-id': string;
}

//
// Display props for the secret type Select. Named rather than written inline in the JSX because an
// inline object literal is checked against Material's div attributes and rejects `data-id`.
//
const SECRET_TYPE_SELECT_DISPLAY_PROPS: ISelectDisplayProps = {
    'data-id': 'secret-type-select',
};

//
// Full CRUD management page for shared secrets stored in the vault.
//
export function SecretsPage() {
    const platform = usePlatform();
    const { secrets, dbs, refresh, addSecret, updateSecret, deleteSecret } = useApp();

    // On a mobile the secrets are shown as cards rather than as a table.
    const isMobile = useIsMobile();

    // Whether the add/edit dialog is open.
    const [dialogOpen, setDialogOpen] = useState(false);

    // The secret being edited (undefined when adding).
    const [editingSecret, setEditingSecret] = useState<ISharedSecretEntry | undefined>(undefined);

    // Current form values.
    const [form, setForm] = useState<ISecretFormState>(emptyFormState());

    // Whether the first delete confirmation dialog is open.
    const [confirmDeleteOpen, setConfirmDeleteOpen] = useState(false);

    // Whether the second delete confirmation dialog is open (used when secret is referenced).
    const [confirmDeleteSecondOpen, setConfirmDeleteSecondOpen] = useState(false);

    // The secret pending deletion.
    const [deletingSecret, setDeletingSecret] = useState<ISharedSecretEntry | undefined>(undefined);

    // Database entries that reference the secret pending deletion.
    const [referencingDatabases, setReferencingDatabases] = useState<IDatabaseEntry[]>([]);

    // Whether a refresh is in progress (drives the spin animation).
    const [refreshing, setRefreshing] = useState(false);

    // The secret being shared via LAN share (undefined when no share is in progress).
    const [sharingSecret, setSharingSecret] = useState<ISharedSecretEntry | undefined>(undefined);

    // Whether the receive-secret dialog is open.
    const [receiveDialogOpen, setReceiveDialogOpen] = useState(false);

    // The secret currently being viewed (undefined when dialog is closed).
    const [viewingSecret, setViewingSecret] = useState<ISharedSecretEntry | undefined>(undefined);

    // Whether the mount refresh has finished, so the list on screen is the loaded one rather than the
    // empty initial state.
    const [loaded, setLoaded] = useState(false);

    // Re-read the secrets/databases lists when the page mounts, so state seeded or changed outside
    // this provider instance (e.g. mobile test setup) is reflected when the page is entered.
    useEffect(() => {
        refresh()
            .then(() => setLoaded(true))
            .catch(err => log.exception('Failed to refresh on secrets page mount:', err as Error));
    }, []);

    // Announced once the secrets have been read, and again whenever the list changes. The count is part
    // of the line because "loaded" alone is ambiguous: the load flag and the list arrive in separate
    // renders, so the line can be emitted once with the list still empty and again with it populated. A
    // smoke test that waited for the bare text matched the first of those and read a row that had not
    // rendered yet, concluding the secret was lost. With the count a test can wait for the state it
    // actually needs. Only visible once secret reads became real keychain round-trips rather than reads
    // of an in-memory cache.
    useEffect(() => {
        if (loaded) {
            log.info(`Secrets page loaded: ${secrets.length} secret(s)`);
        }
    }, [secrets, loaded]);

    //
    // Reloads secrets via the context with a minimum delay so the spin animation is visible.
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
    // Opens the add dialog with a blank form.
    //
    function openAddDialog(): void {
        setEditingSecret(undefined);
        setForm(emptyFormState());
        setDialogOpen(true);
        log.info('Add secret dialog opened');
    }

    //
    // Opens the edit dialog pre-populated with the secret's current values.
    //
    async function openEditDialog(secret: ISharedSecretEntry): Promise<void> {
        setEditingSecret(secret);
        const baseForm: ISecretFormState = {
            ...emptyFormState(),
            name: secret.name,
            type: secret.type,
        };
        const valueJson = await platform.getSecretValue(secret.name);
        const populated = valueJson ? applyValueJson(baseForm, valueJson) : baseForm;
        setForm(populated);
        setDialogOpen(true);
        log.info('Edit secret dialog opened');
    }

    //
    // Saves the form (add or update secret).
    //
    async function handleSave(): Promise<void> {
        const valueJson = buildValueJson(form);
        if (editingSecret) {
            await updateSecret(editingSecret.name, { name: form.name, type: editingSecret.type }, valueJson);
            log.info('Secret updated');
        }
        else {
            await addSecret({ name: form.name, type: form.type }, valueJson);
            log.info('Secret added');
        }
        setDialogOpen(false);
    }

    //
    // Initiates the delete flow — first confirmation step.
    //
    function promptDelete(secret: ISharedSecretEntry): void {
        setDeletingSecret(secret);
        setConfirmDeleteOpen(true);
    }

    //
    // Handles the first confirmation: checks if any databases reference the secret.
    //
    async function handleFirstConfirm(): Promise<void> {
        if (!deletingSecret) {
            return;
        }
        setConfirmDeleteOpen(false);
        const referencing = dbs.filter(
            dbEntry =>
                dbEntry.s3Key === deletingSecret.name ||
                dbEntry.encryptionKey === deletingSecret.name ||
                dbEntry.geocodingKey === deletingSecret.name
        );
        if (referencing.length > 0) {
            setReferencingDatabases(referencing);
            setConfirmDeleteSecondOpen(true);
        }
        else {
            await executeDelete();
        }
    }

    //
    // Performs the actual deletion.
    //
    async function executeDelete(): Promise<void> {
        if (deletingSecret) {
            await deleteSecret(deletingSecret.name);
            setDeletingSecret(undefined);
        }
        setConfirmDeleteSecondOpen(false);
        setReferencingDatabases([]);
    }

    //
    // Renders the type-specific credential fields inside the dialog.
    //
    function renderTypeFields(): React.ReactNode {
        if (form.type === 's3-credentials') {
            return (
                <>
                    <FormControl fullWidth>
                        <FormLabel>Endpoint (optional)</FormLabel>
                        <OutlinedInput
                            size="small"
                            data-id="secret-s3-endpoint-input"
                            value={form.s3Endpoint}
                            onChange={event => setForm(prev => ({ ...prev, s3Endpoint: event.target.value }))}
                        />
                    </FormControl>
                    <FormControl fullWidth>
                        <FormLabel>Region</FormLabel>
                        <OutlinedInput
                            size="small"
                            data-id="secret-s3-region-input"
                            value={form.s3Region}
                            onChange={event => setForm(prev => ({ ...prev, s3Region: event.target.value }))}
                        />
                    </FormControl>
                    <FormControl fullWidth>
                        <FormLabel>Access Key ID</FormLabel>
                        <OutlinedInput
                            size="small"
                            data-id="secret-s3-access-key-input"
                            value={form.s3AccessKeyId}
                            onChange={event => setForm(prev => ({ ...prev, s3AccessKeyId: event.target.value }))}
                        />
                    </FormControl>
                    <FormControl fullWidth>
                        <FormLabel>Secret Access Key</FormLabel>
                        <OutlinedInput
                            size="small"
                            data-id="secret-s3-secret-key-input"
                            type="password"
                            value={form.s3SecretAccessKey}
                            onChange={event => setForm(prev => ({ ...prev, s3SecretAccessKey: event.target.value }))}
                        />
                    </FormControl>
                </>
            );
        }
        if (form.type === 'encryption-key') {
            return (
                <>
                    <FormControl fullWidth>
                        <FormLabel>Private Key PEM</FormLabel>
                        <OutlinedInput
                            data-id="secret-private-key-input"
                            multiline
                            minRows={4}
                            value={form.privateKeyPem}
                            onChange={event => setForm(prev => ({ ...prev, privateKeyPem: event.target.value }))}
                            sx={{
                                '& textarea': {
                                    fontFamily: 'var(--font-mono)',
                                    fontSize: 'var(--text-xs)',
                                    WebkitTextSecurity: 'disc',
                                },
                            }}
                        />
                    </FormControl>
                    <FormControl fullWidth>
                        <FormLabel>Public Key PEM</FormLabel>
                        <OutlinedInput
                            multiline
                            minRows={4}
                            value={form.publicKeyPem}
                            onChange={event => setForm(prev => ({ ...prev, publicKeyPem: event.target.value }))}
                            sx={{
                                '& textarea': {
                                    fontFamily: 'var(--font-mono)',
                                    fontSize: 'var(--text-xs)',
                                },
                            }}
                        />
                    </FormControl>
                </>
            );
        }
        return (
            <FormControl fullWidth>
                <FormLabel>API Key</FormLabel>
                <OutlinedInput
                    size="small"
                    data-id="secret-value-input"
                    type="password"
                    value={form.apiKey}
                    onChange={event => setForm(prev => ({ ...prev, apiKey: event.target.value }))}
                />
            </FormControl>
        );
    }

    //
    // The actions offered for a single secret, in the order they appear in a card's ⋮ menu. Viewing
    // is the card's tap action, so it is not repeated in the menu on mobile.
    //
    function secretActions(secret: ISharedSecretEntry): IEntityCardAction[] {
        return [
            {
                label: 'View',
                icon: <Visibility fontSize="small" />,
                dataId: 'view-secret-button',
                onClick: () => { log.info('View secret dialog opened'); setViewingSecret(secret); },
            },
            {
                label: 'Share',
                icon: <IosShare fontSize="small" />,
                dataId: 'share-secret-button',
                onClick: () => setSharingSecret(secret),
            },
            {
                label: 'Edit',
                icon: <Edit fontSize="small" />,
                dataId: 'edit-secret-button',
                onClick: () => openEditDialog(secret).catch(err => log.exception('Failed to open edit dialog:', err as Error)),
            },
            {
                label: 'Delete',
                icon: <Delete fontSize="small" />,
                danger: true,
                onClick: () => promptDelete(secret),
            },
        ];
    }

    // A mobile has less room round the page's edges, as the style guide's list pages have.
    let pagePadding = 'var(--space-6) var(--space-6) var(--space-8)';
    if (isMobile) {
        pagePadding = 'var(--space-4) var(--space-4) var(--space-8)';
    }

    // The add and edit dialog's title badge: a key to add a secret, a pen to edit one.
    let formDialogIcon = <Key />;
    if (editingSecret) {
        formDialogIcon = <Edit />;
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
                padding: pagePadding,
                paddingInline: `max(${isMobile ? 'var(--space-4)' : 'var(--space-6)'}, calc((100% - var(--space-8) * 30) / 2))`,
            }}
            >
            <MobilePageHeader
                title="Manage Secrets"
                subtitle={secrets.length === 1 ? '1 secret' : `${secrets.length} secrets`}
                refreshing={refreshing}
                onRefresh={() => handleRefresh().catch(err => log.exception('Failed to refresh secrets:', err as Error))}
                primaryAction={{
                    label: 'Add secret',
                    icon: <Add />,
                    dataId: 'add-secret-button',
                    onClick: openAddDialog,
                }}
                secondaryActions={[
                    {
                        label: 'Receive secret',
                        icon: <Download fontSize="small" />,
                        dataId: 'receive-secret-button',
                        onClick: () => setReceiveDialogOpen(true),
                    },
                ]}
                />

            {secrets.length === 0
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
                        <Key fontSize="inherit" />
                    </Box>
                    <Typography
                        variant="subtitle1"
                        sx={{
                            fontSize: 'var(--text-lg)',
                            fontWeight: 'var(--weight-bold)',
                        }}
                        >
                        No secrets yet
                    </Typography>
                    <Typography
                        variant="body2"
                        sx={{
                            color: 'var(--color-text-muted)',
                            fontSize: 'var(--text-sm)',
                        }}
                        >
                        Add a secret, or receive one from another device.
                    </Typography>
                </Box>
            }

            {/* Cards on a mobile (name across the full width, actions in the ⋮ menu), the table on a
                wide screen where the columns are worth having. */}
            {secrets.length > 0 && isMobile
                && <Box>
                    {secrets.map(secret => (
                        <EntityCard
                            key={secret.name}
                            title={secret.name}
                            titleDataId={`secret-row-name-${secret.name}`}
                            subtitle={secret.type}
                            icon={<Key />}
                            onClick={() => { log.info('View secret dialog opened'); setViewingSecret(secret); }}
                            actions={secretActions(secret)}
                            monoTitle={true}
                            subtitleChip={true}
                            />
                    ))}
                </Box>
            }

            {secrets.length > 0 && !isMobile
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
                                <TableCell>Type</TableCell>
                                <TableCell
                                    sx={{
                                        width: 'calc(var(--space-8) * 6)',
                                        whiteSpace: 'nowrap',
                                    }}
                                    >
                                    Actions
                                </TableCell>
                            </TableRow>
                        </TableHead>
                        <TableBody>
                            {secrets.map(secret => (
                                <TableRow key={secret.name}>
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
                                                <Key fontSize="inherit" />
                                            </Box>
                                            <Box
                                                data-id={`secret-row-name-${secret.name}`}
                                                sx={{
                                                    minWidth: 0,
                                                    fontFamily: 'var(--font-mono)',
                                                    fontWeight: 'var(--weight-bold)',
                                                    overflowWrap: 'anywhere',
                                                }}
                                                >
                                                {secret.name}
                                            </Box>
                                        </Box>
                                    </TableCell>
                                    <TableCell>
                                        <Chip
                                            size="small"
                                            label={secret.type}
                                            sx={{
                                                minHeight: 'var(--space-6)',
                                                fontSize: 'var(--text-xs)',
                                                fontWeight: 'var(--weight-bold)',
                                            }}
                                            />
                                    </TableCell>
                                    <TableCell
                                        sx={{
                                            whiteSpace: 'nowrap',
                                        }}
                                        >
                                        <IconButton
                                            data-id="view-secret-button"
                                            size="small"
                                            title="View secret"
                                            onClick={() => { log.info('View secret dialog opened'); setViewingSecret(secret); }}
                                        >
                                            <Visibility fontSize="small" />
                                        </IconButton>
                                        <IconButton
                                            data-id="share-secret-button"
                                            size="small"
                                            title="Share secret"
                                            onClick={() => setSharingSecret(secret)}
                                        >
                                            <IosShare fontSize="small" />
                                        </IconButton>
                                        <IconButton
                                            data-id="edit-secret-button"
                                            size="small"
                                            title="Edit secret"
                                            onClick={() => openEditDialog(secret).catch(err => log.exception('Failed to open edit dialog:', err as Error))}
                                        >
                                            <Edit fontSize="small" />
                                        </IconButton>
                                        <IconButton
                                            data-id="delete-secret-button"
                                            size="small"
                                            title="Delete secret"
                                            onClick={() => promptDelete(secret)}
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

            {/* Add / Edit dialog */}
            <ResponsiveDialog
                open={dialogOpen}
                onClose={() => setDialogOpen(false)}
                minWidth={500}
                maxWidth={700}
                onKeyDown={createDialogKeyHandler(handleSave, false)}
                >
                <IconButton
                    data-id="add-secret-close"
                    aria-label="Close"
                    size="small"
                    onClick={() => setDialogOpen(false)}
                    sx={{
                        position: 'absolute',
                        top: 'var(--space-4)',
                        right: 'var(--space-4)',
                    }}
                >
                    <Close fontSize="small" />
                </IconButton>
                <DialogTitle><DialogIconBadge icon={formDialogIcon} danger={false} />{editingSecret ? 'Edit Secret' : 'Add Secret'}</DialogTitle>
                <DialogContent
                    sx={{
                        display: 'flex',
                        flexDirection: 'column',
                        gap: 'var(--space-4)',
                    }}
                    >
                    <FormControl fullWidth>
                        <FormLabel>Name</FormLabel>
                        <OutlinedInput
                            size="small"
                            data-id="secret-name-input"
                            value={form.name}
                            onChange={event => setForm(prev => ({ ...prev, name: event.target.value }))}
                        />
                    </FormControl>

                    <FormControl fullWidth>
                        <FormLabel>Type</FormLabel>
                        <Select
                            size="small"
                            value={form.type}
                            onChange={event => setForm(prev => ({ ...prev, type: event.target.value }))}
                            disabled={!!editingSecret}
                            SelectDisplayProps={SECRET_TYPE_SELECT_DISPLAY_PROPS}
                        >
                            {SECRET_TYPES.map(secretType => (
                                <MenuItem key={secretType} data-id={`secret-type-option-${secretType}`} value={secretType}>{secretType}</MenuItem>
                            ))}
                        </Select>
                    </FormControl>

                    {renderTypeFields()}
                </DialogContent>
                <DialogActions>
                    <Button data-id="add-secret-cancel" variant="outlined" onClick={() => setDialogOpen(false)}>Cancel</Button>
                    <Button
                        data-id="add-secret-confirm"
                        variant="contained"
                        onClick={() => handleSave().catch(err => log.exception('Save error:', err as Error))}
                    >
                        Save
                    </Button>
                </DialogActions>
            </ResponsiveDialog>

            {/* First delete confirmation */}
            <ResponsiveDialog
                open={confirmDeleteOpen}
                onClose={() => setConfirmDeleteOpen(false)}
                minWidth={400}
                maxWidth={520}
                >
                    <DialogTitle><DialogIconBadge icon={<Delete />} danger={true} />Delete Secret</DialogTitle>
                    <DialogContent>
                        <Typography>
                            Are you sure you want to delete <strong>{deletingSecret?.name}</strong>?
                        </Typography>
                    </DialogContent>
                    <DialogActions>
                        <Button variant="outlined" onClick={() => setConfirmDeleteOpen(false)}>Cancel</Button>
                        <Button
                            variant="outlined"
                            color="error"
                            onClick={() => handleFirstConfirm().catch(err => log.exception('Delete confirm error:', err as Error))}
                        >
                            Delete
                        </Button>
                    </DialogActions>
            </ResponsiveDialog>

            {/* Second delete confirmation (secret is referenced by databases) */}
            <ResponsiveDialog
                open={confirmDeleteSecondOpen}
                onClose={() => setConfirmDeleteSecondOpen(false)}
                minWidth={400}
                maxWidth={520}
                >
                    <DialogTitle><DialogIconBadge icon={<Delete />} danger={true} />Secret In Use</DialogTitle>
                    <DialogContent>
                        <Typography>
                            This secret is used by the following databases:
                        </Typography>
                        <Box
                            component="ul"
                            sx={{
                                margin: 'var(--space-2) 0',
                                paddingLeft: 'var(--space-6)',
                            }}
                            >
                            {referencingDatabases.map(dbEntry => (
                                <li key={dbEntry.name}>{dbEntry.name || dbEntry.path}</li>
                            ))}
                        </Box>
                        <Typography>
                            Delete anyway?
                        </Typography>
                    </DialogContent>
                    <DialogActions>
                        <Button variant="outlined" onClick={() => setConfirmDeleteSecondOpen(false)}>Cancel</Button>
                        <Button
                            variant="outlined"
                            color="error"
                            onClick={() => executeDelete().catch(err => log.exception('Delete error:', err as Error))}
                        >
                            Delete
                        </Button>
                    </DialogActions>
            </ResponsiveDialog>

            {sharingSecret && (
                <ShareSecretDialog
                    open={sharingSecret !== undefined}
                    entry={sharingSecret}
                    onClose={() => setSharingSecret(undefined)}
                />
            )}

            <ReceiveSecretDialog
                open={receiveDialogOpen}
                onClose={() => setReceiveDialogOpen(false)}
            />

            {viewingSecret !== undefined && (
                <ViewSecretDialog
                    open={viewingSecret !== undefined}
                    secret={viewingSecret!}
                    onClose={() => setViewingSecret(undefined)}
                    getSecretValue={platform.getSecretValue}
                />
            )}
        </Box>
    );
}
