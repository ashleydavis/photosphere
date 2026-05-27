import { log } from "utils";
import React, { useState } from 'react';
import Modal from '@mui/joy/Modal';
import ModalDialog from '@mui/joy/ModalDialog';
import DialogTitle from '@mui/joy/DialogTitle';
import DialogContent from '@mui/joy/DialogContent';
import DialogActions from '@mui/joy/DialogActions';
import Button from '@mui/joy/Button';
import Input from '@mui/joy/Input';
import Textarea from '@mui/joy/Textarea';
import FormControl from '@mui/joy/FormControl';
import FormLabel from '@mui/joy/FormLabel';
import { type ISharedSecretEntry } from '../context/platform-context';
import { useApp } from '../context/app-context';
import { buildValueJson, emptyFormState, type ISecretFormState } from '../lib/secrets-form';

export interface ICreateSecretDialogProps {
    // Whether the dialog is open.
    open: boolean;

    // The type of secret to create (pre-selected, not editable).
    secretType: string;

    // Default name to pre-populate the name field.
    defaultName: string;

    // Called when the user cancels.
    onClose: () => void;

    // Called with the newly created secret after a successful save.
    onSave: (newSecret: ISharedSecretEntry) => void;
}

//
// A dialog for quickly creating a shared secret of a specific type,
// used inline from the databases page and create-database modal.
//
export function CreateSecretDialog({ open, secretType, defaultName, onClose, onSave }: ICreateSecretDialogProps) {
    const { addSecret } = useApp();

    const [form, setForm] = useState<ISecretFormState>(() => ({
        ...emptyFormState(),
        name: defaultName,
        type: secretType,
    }));

    //
    // Creates the secret and notifies the parent.
    //
    async function handleSave(): Promise<void> {
        const valueJson = buildValueJson(form);
        const newSecret = await addSecret({ name: form.name.trim(), type: secretType }, valueJson);
        onSave(newSecret);
    }

    //
    // Renders the type-specific credential input fields.
    //
    function renderTypeFields(): React.ReactNode {
        if (secretType === 's3-credentials') {
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
        if (secretType === 'encryption-key') {
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
                    type="password"
                    value={form.apiKey}
                    onChange={event => setForm(prev => ({ ...prev, apiKey: event.target.value }))}
                />
            </FormControl>
        );
    }

    return (
        <Modal open={open} onClose={onClose}>
            <ModalDialog sx={{ minWidth: 480, maxWidth: 640, overflowY: 'auto' }}>
                <DialogTitle>New {secretType} Secret</DialogTitle>
                <DialogContent>
                    <FormControl sx={{ mb: 2 }}>
                        <FormLabel>Name</FormLabel>
                        <Input
                            value={form.name}
                            onChange={event => setForm(prev => ({ ...prev, name: event.target.value }))}
                        />
                    </FormControl>
                    {renderTypeFields()}
                </DialogContent>
                <DialogActions>
                    <Button variant="plain" onClick={onClose}>Cancel</Button>
                    <Button onClick={() => handleSave().catch(err => log.exception('Create secret error:', err as Error))}>Create</Button>
                </DialogActions>
            </ModalDialog>
        </Modal>
    );
}
