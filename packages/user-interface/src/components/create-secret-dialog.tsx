import { log } from "utils";
import React, { useState } from 'react';
import DialogTitle from '@mui/material/DialogTitle';
import DialogContent from '@mui/material/DialogContent';
import DialogActions from '@mui/material/DialogActions';
import Button from '@mui/material/Button';
import OutlinedInput from '@mui/material/OutlinedInput';
import FormControl from '@mui/material/FormControl';
import FormLabel from '@mui/material/FormLabel';
import { type ISharedSecretEntry } from '../context/platform-context';
import { useApp } from '../context/app-context';
import { buildValueJson, emptyFormState, type ISecretFormState } from '../lib/secrets-form';
import { createDialogKeyHandler } from '../lib/dialog-keys';
import Key from '@mui/icons-material/Key';
import { ResponsiveDialog } from './responsive-dialog';
import { DialogIconBadge } from './dialog-icon-badge';

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
                    <FormControl fullWidth>
                        <FormLabel>Endpoint (optional)</FormLabel>
                        <OutlinedInput
                            size="small"
                            data-id="create-secret-s3-endpoint-input"
                            value={form.s3Endpoint}
                            onChange={event => setForm(prev => ({ ...prev, s3Endpoint: event.target.value }))}
                        />
                    </FormControl>
                    <FormControl fullWidth>
                        <FormLabel>Region</FormLabel>
                        <OutlinedInput
                            size="small"
                            data-id="create-secret-s3-region-input"
                            value={form.s3Region}
                            onChange={event => setForm(prev => ({ ...prev, s3Region: event.target.value }))}
                        />
                    </FormControl>
                    <FormControl fullWidth>
                        <FormLabel>Access Key ID</FormLabel>
                        <OutlinedInput
                            size="small"
                            data-id="create-secret-s3-access-key-input"
                            value={form.s3AccessKeyId}
                            onChange={event => setForm(prev => ({ ...prev, s3AccessKeyId: event.target.value }))}
                        />
                    </FormControl>
                    <FormControl fullWidth>
                        <FormLabel>Secret Access Key</FormLabel>
                        <OutlinedInput
                            size="small"
                            data-id="create-secret-s3-secret-key-input"
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
                    <FormControl fullWidth>
                        <FormLabel>Private Key PEM</FormLabel>
                        <OutlinedInput
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
                    data-id="create-secret-api-key-input"
                    type="password"
                    value={form.apiKey}
                    onChange={event => setForm(prev => ({ ...prev, apiKey: event.target.value }))}
                />
            </FormControl>
        );
    }

    return (
        <ResponsiveDialog
            open={open}
            onClose={onClose}
            minWidth={480}
            maxWidth={640}
            onKeyDown={createDialogKeyHandler(handleSave, false)}
            >
            <DialogTitle><DialogIconBadge icon={<Key />} danger={false} />New {secretType} Secret</DialogTitle>
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
                        data-id="create-secret-name-input"
                        value={form.name}
                        onChange={event => setForm(prev => ({ ...prev, name: event.target.value }))}
                    />
                </FormControl>
                {renderTypeFields()}
            </DialogContent>
            <DialogActions>
                <Button variant="outlined" onClick={onClose}>Cancel</Button>
                <Button data-id="create-secret-confirm" variant="contained" onClick={() => handleSave().catch(err => log.exception('Create secret error:', err as Error))}>Create</Button>
            </DialogActions>
        </ResponsiveDialog>
    );
}
