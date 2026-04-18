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
import AccordionGroup from '@mui/joy/AccordionGroup';
import Accordion from '@mui/joy/Accordion';
import AccordionSummary from '@mui/joy/AccordionSummary';
import AccordionDetails from '@mui/joy/AccordionDetails';
import { Edit, Delete, Add } from '@mui/icons-material';
import { usePlatform, type IDatabaseEntry, type IDatabaseSecrets, type IS3Credentials, type IEncryptionKeyPair } from '../../context/platform-context';

//
// Form state for the add/edit dialog.
//
interface IDatabaseFormState {
    // Non-secret fields
    name: string;
    description: string;
    path: string;

    // S3 credentials
    s3Endpoint: string;
    s3Region: string;
    s3AccessKeyId: string;
    s3SecretAccessKey: string;

    // Encryption key pair
    privateKeyPem: string;
    publicKeyPem: string;

    // Geocoding API key
    geocodingApiKey: string;
}

//
// Returns an empty form state.
//
function emptyFormState(): IDatabaseFormState {
    return {
        name: '',
        description: '',
        path: '',
        s3Endpoint: '',
        s3Region: '',
        s3AccessKeyId: '',
        s3SecretAccessKey: '',
        privateKeyPem: '',
        publicKeyPem: '',
        geocodingApiKey: '',
    };
}

//
// Full CRUD management page for configured database entries.
//
export function DatabasesPage() {
    const platform = usePlatform();

    // All known database entries
    const [databases, setDatabases] = useState<IDatabaseEntry[]>([]);

    // Whether the add/edit dialog is open
    const [dialogOpen, setDialogOpen] = useState(false);

    // Entry being edited (undefined when adding new)
    const [editingEntry, setEditingEntry] = useState<IDatabaseEntry | undefined>(undefined);

    // Current form values
    const [form, setForm] = useState<IDatabaseFormState>(emptyFormState());

    // Whether the remove confirmation dialog is open
    const [confirmRemoveOpen, setConfirmRemoveOpen] = useState(false);

    // Entry pending removal
    const [removingEntry, setRemovingEntry] = useState<IDatabaseEntry | undefined>(undefined);

    //
    // Loads database entries from the platform.
    //
    async function loadDatabases(): Promise<void> {
        const entries = await platform.getDatabases();
        setDatabases(entries);
    }

    useEffect(() => {
        loadDatabases().catch(err => console.error('Failed to load databases:', err));
    }, []);

    //
    // Opens the add dialog with a blank form.
    //
    function openAddDialog(): void {
        setEditingEntry(undefined);
        setForm(emptyFormState());
        setDialogOpen(true);
    }

    //
    // Opens the edit dialog pre-populated with the entry's values and secrets.
    //
    async function openEditDialog(entry: IDatabaseEntry): Promise<void> {
        setEditingEntry(entry);
        const secrets = await platform.getDatabaseSecrets(entry.id);
        setForm({
            name: entry.name,
            description: entry.description,
            path: entry.path,
            s3Endpoint: secrets.s3Credentials?.endpoint ?? '',
            s3Region: secrets.s3Credentials?.region ?? '',
            s3AccessKeyId: secrets.s3Credentials?.accessKeyId ?? '',
            s3SecretAccessKey: secrets.s3Credentials?.secretAccessKey ?? '',
            privateKeyPem: secrets.encryptionKeyPair?.privateKeyPem ?? '',
            publicKeyPem: secrets.encryptionKeyPair?.publicKeyPem ?? '',
            geocodingApiKey: secrets.geocodingApiKey ?? '',
        });
        setDialogOpen(true);
    }

    //
    // Saves the form (add or update entry plus secrets).
    //
    async function handleSave(): Promise<void> {
        const entryData: Omit<IDatabaseEntry, 'id'> = {
            name: form.name,
            description: form.description,
            path: form.path,
        };

        let savedEntry: IDatabaseEntry;
        if (editingEntry) {
            savedEntry = { ...editingEntry, ...entryData };
            await platform.updateDatabase(savedEntry);
        }
        else {
            savedEntry = await platform.addDatabase(entryData);
        }

        const secrets: IDatabaseSecrets = {};

        if (form.s3Region || form.s3AccessKeyId || form.s3SecretAccessKey) {
            const s3Creds: IS3Credentials = {
                region: form.s3Region,
                accessKeyId: form.s3AccessKeyId,
                secretAccessKey: form.s3SecretAccessKey,
            };
            if (form.s3Endpoint) {
                s3Creds.endpoint = form.s3Endpoint;
            }
            secrets.s3Credentials = s3Creds;
        }

        if (form.privateKeyPem && form.publicKeyPem) {
            const keyPair: IEncryptionKeyPair = {
                privateKeyPem: form.privateKeyPem,
                publicKeyPem: form.publicKeyPem,
            };
            secrets.encryptionKeyPair = keyPair;
        }

        if (form.geocodingApiKey) {
            secrets.geocodingApiKey = form.geocodingApiKey;
        }

        await platform.setDatabaseSecrets(savedEntry.id, secrets);

        setDialogOpen(false);
        await loadDatabases();
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
            await platform.removeDatabaseEntry(removingEntry.id);
            setRemovingEntry(undefined);
        }
        setConfirmRemoveOpen(false);
        await loadDatabases();
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

    return (
        <Box sx={{ p: 3 }}>
            <Box sx={{ display: 'flex', alignItems: 'center', mb: 2 }}>
                <Typography level="h3">Databases</Typography>
                <Box sx={{ flexGrow: 1 }} />
                <Button
                    startDecorator={<Add />}
                    onClick={openAddDialog}
                >
                    Add Database
                </Button>
            </Box>

            <Table>
                <thead>
                    <tr>
                        <th>Name</th>
                        <th>Description</th>
                        <th>Path</th>
                        <th>Origin</th>
                        <th style={{ width: '80px' }}>Actions</th>
                    </tr>
                </thead>
                <tbody>
                    {databases.map(entry => (
                        <tr key={entry.id}>
                            <td>{entry.name}</td>
                            <td>{entry.description}</td>
                            <td>{entry.path}</td>
                            <td>{entry.origin ?? ''}</td>
                            <td>
                                <IconButton
                                    size="sm"
                                    variant="plain"
                                    onClick={() => openEditDialog(entry).catch(err => console.error('Failed to open edit dialog:', err))}
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

                        <AccordionGroup>
                            <Accordion>
                                <AccordionSummary>S3 Credentials</AccordionSummary>
                                <AccordionDetails>
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
                                </AccordionDetails>
                            </Accordion>

                            <Accordion>
                                <AccordionSummary>Encryption Key</AccordionSummary>
                                <AccordionDetails>
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
                                </AccordionDetails>
                            </Accordion>

                            <Accordion>
                                <AccordionSummary>Geocoding</AccordionSummary>
                                <AccordionDetails>
                                    <FormControl sx={{ mb: 1 }}>
                                        <FormLabel>API Key</FormLabel>
                                        <Input
                                            value={form.geocodingApiKey}
                                            onChange={event => setForm(prev => ({ ...prev, geocodingApiKey: event.target.value }))}
                                        />
                                    </FormControl>
                                </AccordionDetails>
                            </Accordion>
                        </AccordionGroup>
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
                            This only removes the entry from Photosphere's database list and deletes its stored secrets.
                            No files on disk will be deleted.
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
        </Box>
    );
}
