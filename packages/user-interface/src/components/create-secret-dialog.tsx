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
import { usePlatform, type ISharedSecretEntry } from '../context/platform-context';

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
    const platform = usePlatform();

    const [name, setName] = useState(defaultName);

    // S3 credentials fields.
    const [s3Endpoint, setS3Endpoint] = useState('');
    const [s3Region, setS3Region] = useState('');
    const [s3AccessKeyId, setS3AccessKeyId] = useState('');
    const [s3SecretAccessKey, setS3SecretAccessKey] = useState('');

    // Encryption key fields.
    const [privateKeyPem, setPrivateKeyPem] = useState('');
    const [publicKeyPem, setPublicKeyPem] = useState('');

    // API key field.
    const [apiKey, setApiKey] = useState('');

    //
    // Builds the JSON value string from the current type-specific fields.
    //
    function buildValueJson(): string {
        if (secretType === 's3-credentials') {
            const obj: Record<string, string> = {
                region: s3Region,
                accessKeyId: s3AccessKeyId,
                secretAccessKey: s3SecretAccessKey,
            };
            if (s3Endpoint) {
                obj.endpoint = s3Endpoint;
            }
            return JSON.stringify(obj);
        }
        if (secretType === 'encryption-key') {
            return JSON.stringify({ privateKeyPem, publicKeyPem });
        }
        return JSON.stringify({ apiKey });
    }

    //
    // Creates the secret and notifies the parent.
    //
    async function handleSave(): Promise<void> {
        const valueJson = buildValueJson();
        const newSecret = await platform.addSecret({ name, type: secretType }, valueJson);
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
                        <Input value={s3Endpoint} onChange={event => setS3Endpoint(event.target.value)} />
                    </FormControl>
                    <FormControl sx={{ mb: 1 }}>
                        <FormLabel>Region</FormLabel>
                        <Input value={s3Region} onChange={event => setS3Region(event.target.value)} />
                    </FormControl>
                    <FormControl sx={{ mb: 1 }}>
                        <FormLabel>Access Key ID</FormLabel>
                        <Input value={s3AccessKeyId} onChange={event => setS3AccessKeyId(event.target.value)} />
                    </FormControl>
                    <FormControl sx={{ mb: 1 }}>
                        <FormLabel>Secret Access Key</FormLabel>
                        <Input type="password" value={s3SecretAccessKey} onChange={event => setS3SecretAccessKey(event.target.value)} />
                    </FormControl>
                </>
            );
        }
        if (secretType === 'encryption-key') {
            return (
                <>
                    <FormControl sx={{ mb: 1 }}>
                        <FormLabel>Private Key PEM</FormLabel>
                        <Textarea minRows={4} value={privateKeyPem} onChange={event => setPrivateKeyPem(event.target.value)} />
                    </FormControl>
                    <FormControl sx={{ mb: 1 }}>
                        <FormLabel>Public Key PEM</FormLabel>
                        <Textarea minRows={4} value={publicKeyPem} onChange={event => setPublicKeyPem(event.target.value)} />
                    </FormControl>
                </>
            );
        }
        return (
            <FormControl sx={{ mb: 1 }}>
                <FormLabel>API Key</FormLabel>
                <Input value={apiKey} onChange={event => setApiKey(event.target.value)} />
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
                        <Input value={name} onChange={event => setName(event.target.value)} />
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
