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
import Textarea from '@mui/joy/Textarea';
import FormControl from '@mui/joy/FormControl';
import FormLabel from '@mui/joy/FormLabel';
import Select from '@mui/joy/Select';
import Option from '@mui/joy/Option';
import { Edit, Delete, Add, Refresh, IosShare, Visibility } from '@mui/icons-material';
import { usePlatform, type ISharedSecretEntry, type IDatabaseEntry } from '../../context/platform-context';
import { useApp } from '../../context/app-context';
import { ShareSecretDialog } from '../../components/share-secret-dialog';
import { ReceiveSecretDialog } from '../../components/receive-secret-dialog';
import { ViewSecretDialog } from '../../components/view-secret-dialog';
import { applyValueJson, buildValueJson, emptyFormState, type ISecretFormState } from '../../lib/secrets-form';
import { createDialogKeyHandler } from '../../lib/dialog-keys';

//
// The supported secret type identifiers.
//
const SECRET_TYPES = ['s3-credentials', 'encryption-key', 'api-key'] as const;

//
// Full CRUD management page for shared secrets stored in the vault.
//
export function SecretsPage() {
    const platform = usePlatform();
    const { secrets, dbs, refresh, addSecret, updateSecret, deleteSecret } = useApp();

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

    useEffect(() => {
        log.info('Secrets page loaded');
    }, [secrets]);

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
                    <FormControl sx={{ mb: 1 }}>
                        <FormLabel>Endpoint (optional)</FormLabel>
                        <Input
                            value={form.s3Endpoint}
                            onChange={event => setForm(prev => ({ ...prev, s3Endpoint: event.target.value }))}
                        />
                    </FormControl>
                    <FormControl sx={{ mb: 1 }}>
                        <FormLabel>Region</FormLabel>
                        <Input
                            data-id="secret-s3-region-input"
                            value={form.s3Region}
                            onChange={event => setForm(prev => ({ ...prev, s3Region: event.target.value }))}
                        />
                    </FormControl>
                    <FormControl sx={{ mb: 1 }}>
                        <FormLabel>Access Key ID</FormLabel>
                        <Input
                            value={form.s3AccessKeyId}
                            onChange={event => setForm(prev => ({ ...prev, s3AccessKeyId: event.target.value }))}
                        />
                    </FormControl>
                    <FormControl sx={{ mb: 1 }}>
                        <FormLabel>Secret Access Key</FormLabel>
                        <Input
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
                    <FormControl sx={{ mb: 1 }}>
                        <FormLabel>Private Key PEM</FormLabel>
                        <Textarea
                            minRows={4}
                            value={form.privateKeyPem}
                            onChange={event => setForm(prev => ({ ...prev, privateKeyPem: event.target.value }))}
                            slotProps={{ textarea: { sx: { WebkitTextSecurity: 'disc' } } }}
                        />
                    </FormControl>
                    <FormControl sx={{ mb: 1 }}>
                        <FormLabel>Public Key PEM</FormLabel>
                        <Textarea
                            minRows={4}
                            value={form.publicKeyPem}
                            onChange={event => setForm(prev => ({ ...prev, publicKeyPem: event.target.value }))}
                        />
                    </FormControl>
                </>
            );
        }
        return (
            <FormControl sx={{ mb: 1 }}>
                <FormLabel>API Key</FormLabel>
                <Input
                    data-id="secret-value-input"
                    type="password"
                    value={form.apiKey}
                    onChange={event => setForm(prev => ({ ...prev, apiKey: event.target.value }))}
                />
            </FormControl>
        );
    }

    return (
        <Box sx={{ p: 3 }}>
            <Box sx={{ display: 'flex', alignItems: 'center', mb: 2 }}>
                <Typography level="h3">Manage Secrets</Typography>
                <Box sx={{ flexGrow: 1 }} />
                <IconButton
                    variant="outlined"
                    sx={{ mr: 1 }}
                    disabled={refreshing}
                    title="Refresh"
                    onClick={() => handleRefresh().catch(err => log.exception('Failed to refresh secrets:', err as Error))}
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
                    data-id="add-secret-button"
                    startDecorator={<Add />}
                    sx={{ mr: 1 }}
                    onClick={openAddDialog}
                >
                    Add secret
                </Button>
                <Button
                    data-id="receive-secret-button"
                    variant="outlined"
                    onClick={() => setReceiveDialogOpen(true)}
                >
                    Receive secret
                </Button>
            </Box>

            <Table>
                <thead>
                    <tr>
                        <th>Name</th>
                        <th>Type</th>
                        <th style={{ width: '140px', whiteSpace: 'nowrap' }}>Actions</th>
                    </tr>
                </thead>
                <tbody>
                    {secrets.length === 0 && (
                        <tr>
                            <td colSpan={3}>
                               <p className="pt-2 text-gray-500">No secrets yet. Click Add secret to create one, or Receive secret to import one from another device.</p>
                            </td>
                        </tr>
                    )}
                    {secrets.map(secret => (
                        <tr key={secret.name}>
                            <td data-id={`secret-row-name-${secret.name}`}>{secret.name}</td>
                            <td>{secret.type}</td>
                            <td style={{ whiteSpace: 'nowrap' }}>
                                <IconButton
                                    data-id="view-secret-button"
                                    size="sm"
                                    variant="plain"
                                    title="View secret"
                                    onClick={() => { log.info('View secret dialog opened'); setViewingSecret(secret); }}
                                >
                                    <Visibility fontSize="small" />
                                </IconButton>
                                <IconButton
                                    data-id="share-secret-button"
                                    size="sm"
                                    variant="plain"
                                    title="Share secret"
                                    onClick={() => setSharingSecret(secret)}
                                >
                                    <IosShare fontSize="small" />
                                </IconButton>
                                <IconButton
                                    data-id="edit-secret-button"
                                    size="sm"
                                    variant="plain"
                                    title="Edit secret"
                                    onClick={() => openEditDialog(secret).catch(err => log.exception('Failed to open edit dialog:', err as Error))}
                                >
                                    <Edit fontSize="small" />
                                </IconButton>
                                <IconButton
                                    size="sm"
                                    variant="plain"
                                    color="danger"
                                    title="Delete secret"
                                    onClick={() => promptDelete(secret)}
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
                <ModalDialog
                    onKeyDown={createDialogKeyHandler(handleSave, false)}
                    sx={{ minWidth: 500, maxWidth: 700, overflowY: 'auto' }}
                >
                    <ModalClose />
                    <DialogTitle>{editingSecret ? 'Edit Secret' : 'Add Secret'}</DialogTitle>
                    <DialogContent>
                        <FormControl sx={{ mb: 1 }}>
                            <FormLabel>Name</FormLabel>
                            <Input
                                data-id="secret-name-input"
                                value={form.name}
                                onChange={event => setForm(prev => ({ ...prev, name: event.target.value }))}
                            />
                        </FormControl>

                        <FormControl sx={{ mb: 2 }}>
                            <FormLabel>Type</FormLabel>
                            <Select
                                value={form.type}
                                onChange={(_event, value) => setForm(prev => ({ ...prev, type: value as string }))}
                                disabled={!!editingSecret}
                            >
                                {SECRET_TYPES.map(secretType => (
                                    <Option key={secretType} value={secretType}>{secretType}</Option>
                                ))}
                            </Select>
                        </FormControl>

                        {renderTypeFields()}
                    </DialogContent>
                    <DialogActions>
                        <Button variant="plain" onClick={() => setDialogOpen(false)}>Cancel</Button>
                        <Button
                            data-id="add-secret-confirm"
                            onClick={() => handleSave().catch(err => log.exception('Save error:', err as Error))}
                        >
                            Save
                        </Button>
                    </DialogActions>
                </ModalDialog>
            </Modal>

            {/* First delete confirmation */}
            <Modal open={confirmDeleteOpen} onClose={() => setConfirmDeleteOpen(false)}>
                <ModalDialog onKeyDown={createDialogKeyHandler(handleFirstConfirm, false)}>
                    <DialogTitle>Delete Secret</DialogTitle>
                    <DialogContent>
                        <Typography>
                            Are you sure you want to delete <strong>{deletingSecret?.name}</strong>?
                        </Typography>
                    </DialogContent>
                    <DialogActions>
                        <Button variant="plain" onClick={() => setConfirmDeleteOpen(false)}>Cancel</Button>
                        <Button
                            color="danger"
                            onClick={() => handleFirstConfirm().catch(err => log.exception('Delete confirm error:', err as Error))}
                        >
                            Delete
                        </Button>
                    </DialogActions>
                </ModalDialog>
            </Modal>

            {/* Second delete confirmation (secret is referenced by databases) */}
            <Modal open={confirmDeleteSecondOpen} onClose={() => setConfirmDeleteSecondOpen(false)}>
                <ModalDialog onKeyDown={createDialogKeyHandler(executeDelete, false)}>
                    <DialogTitle>Secret In Use</DialogTitle>
                    <DialogContent>
                        <Typography>
                            This secret is used by the following databases:
                        </Typography>
                        <Box component="ul" sx={{ mt: 1, pl: 2 }}>
                            {referencingDatabases.map(dbEntry => (
                                <li key={dbEntry.name}>{dbEntry.name || dbEntry.path}</li>
                            ))}
                        </Box>
                        <Typography sx={{ mt: 1 }}>
                            Delete anyway?
                        </Typography>
                    </DialogContent>
                    <DialogActions>
                        <Button variant="plain" onClick={() => setConfirmDeleteSecondOpen(false)}>Cancel</Button>
                        <Button
                            color="danger"
                            onClick={() => executeDelete().catch(err => log.exception('Delete error:', err as Error))}
                        >
                            Delete
                        </Button>
                    </DialogActions>
                </ModalDialog>
            </Modal>

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
