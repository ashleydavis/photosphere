import React, { useEffect, useState } from 'react';
import Box from '@mui/joy/Box';
import Typography from '@mui/joy/Typography';
import Button from '@mui/joy/Button';
import Table from '@mui/joy/Table';
import IconButton from '@mui/joy/IconButton';
import Modal from '@mui/joy/Modal';
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
import { Edit, Delete, Add } from '@mui/icons-material';
import { usePlatform, type ISharedSecretEntry, type IDatabaseEntry } from '../../context/platform-context';

//
// The supported secret type identifiers.
//
const SECRET_TYPES = ['s3-credentials', 'encryption-key', 'api-key'] as const;

//
// Form state for the add/edit secret dialog.
//
interface ISecretFormState {
    // Human-readable label for the secret.
    name: string;

    // The category of secret.
    type: string;

    // S3 credentials fields.
    s3Endpoint: string;
    s3Region: string;
    s3AccessKeyId: string;
    s3SecretAccessKey: string;

    // Encryption key fields.
    privateKeyPem: string;
    publicKeyPem: string;

    // API key field.
    apiKey: string;
}

//
// Returns an empty form state.
//
function emptyFormState(): ISecretFormState {
    return {
        name: '',
        type: 's3-credentials',
        s3Endpoint: '',
        s3Region: '',
        s3AccessKeyId: '',
        s3SecretAccessKey: '',
        privateKeyPem: '',
        publicKeyPem: '',
        apiKey: '',
    };
}

//
// Serialises the type-specific fields from form state to a JSON value string.
//
function buildValueJson(form: ISecretFormState): string {
    if (form.type === 's3-credentials') {
        const obj: Record<string, string> = {
            region: form.s3Region,
            accessKeyId: form.s3AccessKeyId,
            secretAccessKey: form.s3SecretAccessKey,
        };
        if (form.s3Endpoint) {
            obj.endpoint = form.s3Endpoint;
        }
        return JSON.stringify(obj);
    }
    if (form.type === 'encryption-key') {
        return JSON.stringify({ privateKeyPem: form.privateKeyPem, publicKeyPem: form.publicKeyPem });
    }
    return JSON.stringify({ apiKey: form.apiKey });
}

//
// Populates type-specific form fields from a raw vault value string.
//
function applyValueJson(form: ISecretFormState, valueJson: string): ISecretFormState {
    const parsed = JSON.parse(valueJson);
    if (form.type === 's3-credentials') {
        return {
            ...form,
            s3Endpoint: parsed.endpoint ?? '',
            s3Region: parsed.region ?? '',
            s3AccessKeyId: parsed.accessKeyId ?? '',
            s3SecretAccessKey: parsed.secretAccessKey ?? '',
        };
    }
    if (form.type === 'encryption-key') {
        return {
            ...form,
            privateKeyPem: parsed.privateKeyPem ?? '',
            publicKeyPem: parsed.publicKeyPem ?? '',
        };
    }
    return { ...form, apiKey: parsed.apiKey ?? '' };
}

//
// Full CRUD management page for shared secrets stored in the vault.
//
export function SecretsPage() {
    const platform = usePlatform();

    // All known shared secret entries.
    const [secrets, setSecrets] = useState<ISharedSecretEntry[]>([]);

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

    //
    // Loads all shared secrets from the platform.
    //
    async function loadSecrets(): Promise<void> {
        const entries = await platform.listSecrets();
        setSecrets(entries);
    }

    useEffect(() => {
        loadSecrets().catch(err => console.error('Failed to load secrets:', err));
    }, []);

    //
    // Opens the add dialog with a blank form.
    //
    function openAddDialog(): void {
        setEditingSecret(undefined);
        setForm(emptyFormState());
        setDialogOpen(true);
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
        const valueJson = await platform.getSecretValue(secret.id);
        const populated = valueJson ? applyValueJson(baseForm, valueJson) : baseForm;
        setForm(populated);
        setDialogOpen(true);
    }

    //
    // Saves the form (add or update secret).
    //
    async function handleSave(): Promise<void> {
        const valueJson = buildValueJson(form);
        if (editingSecret) {
            await platform.updateSecret({ ...editingSecret, name: form.name }, valueJson);
        }
        else {
            await platform.addSecret({ name: form.name, type: form.type }, valueJson);
        }
        setDialogOpen(false);
        await loadSecrets();
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
        const allDatabases = await platform.getDatabases();
        const referencing = allDatabases.filter(
            dbEntry =>
                dbEntry.s3CredentialId === deletingSecret.id ||
                dbEntry.encryptionKeyId === deletingSecret.id ||
                dbEntry.geocodingKeyId === deletingSecret.id
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
            await platform.deleteSecret(deletingSecret.id);
            setDeletingSecret(undefined);
        }
        setConfirmDeleteSecondOpen(false);
        setReferencingDatabases([]);
        await loadSecrets();
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
                <Button
                    startDecorator={<Add />}
                    onClick={openAddDialog}
                >
                    Add Secret
                </Button>
            </Box>

            <Table>
                <thead>
                    <tr>
                        <th>Name</th>
                        <th>Type</th>
                        <th style={{ width: '80px' }}>Actions</th>
                    </tr>
                </thead>
                <tbody>
                    {secrets.map(secret => (
                        <tr key={secret.id}>
                            <td>{secret.name}</td>
                            <td>{secret.type}</td>
                            <td>
                                <IconButton
                                    size="sm"
                                    variant="plain"
                                    onClick={() => openEditDialog(secret).catch(err => console.error('Failed to open edit dialog:', err))}
                                >
                                    <Edit fontSize="small" />
                                </IconButton>
                                <IconButton
                                    size="sm"
                                    variant="plain"
                                    color="danger"
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
                <ModalDialog sx={{ minWidth: 500, maxWidth: 700, overflowY: 'auto' }}>
                    <DialogTitle>{editingSecret ? 'Edit Secret' : 'Add Secret'}</DialogTitle>
                    <DialogContent>
                        <FormControl sx={{ mb: 1 }}>
                            <FormLabel>Name</FormLabel>
                            <Input
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
                        <Button onClick={() => handleSave().catch(err => console.error('Save error:', err))}>Save</Button>
                    </DialogActions>
                </ModalDialog>
            </Modal>

            {/* First delete confirmation */}
            <Modal open={confirmDeleteOpen} onClose={() => setConfirmDeleteOpen(false)}>
                <ModalDialog>
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
                            onClick={() => handleFirstConfirm().catch(err => console.error('Delete confirm error:', err))}
                        >
                            Delete
                        </Button>
                    </DialogActions>
                </ModalDialog>
            </Modal>

            {/* Second delete confirmation (secret is referenced by databases) */}
            <Modal open={confirmDeleteSecondOpen} onClose={() => setConfirmDeleteSecondOpen(false)}>
                <ModalDialog>
                    <DialogTitle>Secret In Use</DialogTitle>
                    <DialogContent>
                        <Typography>
                            This secret is used by the following databases:
                        </Typography>
                        <Box component="ul" sx={{ mt: 1, pl: 2 }}>
                            {referencingDatabases.map(dbEntry => (
                                <li key={dbEntry.id}>{dbEntry.name || dbEntry.path}</li>
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
                            onClick={() => executeDelete().catch(err => console.error('Delete error:', err))}
                        >
                            Delete
                        </Button>
                    </DialogActions>
                </ModalDialog>
            </Modal>
        </Box>
    );
}
