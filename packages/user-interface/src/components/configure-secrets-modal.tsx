import React, { useEffect, useState } from 'react';
import { log } from 'utils';
import Box from '@mui/joy/Box';
import Button from '@mui/joy/Button';
import DialogActions from '@mui/joy/DialogActions';
import DialogContent from '@mui/joy/DialogContent';
import DialogTitle from '@mui/joy/DialogTitle';
import FormControl from '@mui/joy/FormControl';
import FormLabel from '@mui/joy/FormLabel';
import Modal from '@mui/joy/Modal';
import ModalDialog from '@mui/joy/ModalDialog';
import Option from '@mui/joy/Option';
import Select from '@mui/joy/Select';
import type { ISharedSecretEntry } from '../context/platform-context';
import { CreateSecretDialog } from './create-secret-dialog';

//
// Vault-secret references for a database entry. Each field holds the chosen vault secret name,
// or undefined when the user has not selected one.
//
export interface IDatabaseSecretsSelection {
    //
    // Vault secret name for the S3 credentials. Undefined for non-S3 databases.
    //
    s3Key: string | undefined;

    //
    // Vault secret name for the encryption key. Undefined for unencrypted databases.
    //
    encryptionKey: string | undefined;

    //
    // Vault secret name for the Google geocoding API key. Undefined when geocoding is not configured.
    //
    geocodingKey: string | undefined;
}

//
// Which secret fields the parent wants to expose. Defaults to all three.
//
export type ConfigureSecretsField = 's3' | 'encryption' | 'geocoding';

//
// Props for ConfigureSecretsModal.
//
export interface IConfigureSecretsModalProps {
    //
    // Whether the modal is visible.
    //
    open: boolean;

    //
    // Initial secret selections shown when the modal opens.
    //
    initialValue: IDatabaseSecretsSelection;

    //
    // Vault entries available for each secret type. The modal does not load them itself —
    // the parent loads and refreshes them.
    //
    s3Secrets: ISharedSecretEntry[];
    encryptionSecrets: ISharedSecretEntry[];
    geocodingSecrets: ISharedSecretEntry[];

    //
    // Fired when the user clicks Save. The modal does not close itself — the parent does so
    // after applying the selection.
    //
    onSave: (next: IDatabaseSecretsSelection) => void;

    //
    // Fired when the user dismisses the modal without saving.
    //
    onClose: () => void;

    //
    // Optional callback fired after a new secret has been quick-created. The parent should reload
    // its secret lists so the new entry is included in the dropdowns. The newly created secret is
    // selected automatically before this callback fires.
    //
    onSecretCreated?: () => Promise<void>;

    //
    // Default name suggested by the quick-create dialog (e.g. the database name or path).
    //
    quickCreateDefaultName?: string;

    //
    // Which secret rows to render. Defaults to all three.
    //
    fields?: ConfigureSecretsField[];
}

//
// Popup modal that lets the user pick the vault-secret references for a database entry
// (S3 credentials, encryption key, geocoding API key) with a "+ New" button per row to
// quick-create a secret via CreateSecretDialog. Reusable across the Edit Database and
// Replicate Database flows so secret configuration is identical everywhere.
//
export function ConfigureSecretsModal({
    open,
    initialValue,
    s3Secrets,
    encryptionSecrets,
    geocodingSecrets,
    onSave,
    onClose,
    onSecretCreated,
    quickCreateDefaultName,
    fields = ['s3', 'encryption', 'geocoding'],
}: IConfigureSecretsModalProps) {

    //
    // Working copy of the selections. Reset each time the modal opens so Cancel discards changes.
    //
    const [working, setWorking] = useState<IDatabaseSecretsSelection>(initialValue);

    //
    // The secret type currently being quick-created, or undefined when the quick-create dialog is closed.
    //
    const [quickCreateType, setQuickCreateType] = useState<string | undefined>(undefined);

    useEffect(() => {
        if (open) {
            setWorking(initialValue);
        }
    }, [open, initialValue]);

    //
    // Handles the user picking a newly created secret. Auto-selects it for the matching field,
    // then notifies the parent so it can refresh its secret lists.
    //
    async function handleQuickCreateSave(newSecret: ISharedSecretEntry): Promise<void> {
        setQuickCreateType(undefined);
        if (newSecret.type === 's3-credentials') {
            setWorking(prev => ({ ...prev, s3Key: newSecret.name }));
        }
        else if (newSecret.type === 'encryption-key') {
            setWorking(prev => ({ ...prev, encryptionKey: newSecret.name }));
        }
        else if (newSecret.type === 'api-key') {
            setWorking(prev => ({ ...prev, geocodingKey: newSecret.name }));
        }
        if (onSecretCreated) {
            await onSecretCreated();
        }
    }

    //
    // Renders one secret selector row with a dropdown and a "+ New" button.
    //
    function renderSecretSelector(
        label: string,
        options: ISharedSecretEntry[],
        selectedName: string | undefined,
        onSelectionChange: (name: string | undefined) => void,
        secretType: string,
    ): React.ReactNode {
        return (
            <FormControl sx={{ mb: 1 }}>
                <FormLabel>{label}</FormLabel>
                <Box sx={{ display: 'flex', gap: 1 }}>
                    <Select
                        sx={{ flexGrow: 1 }}
                        value={selectedName ?? ''}
                        onChange={(_event, selected) => onSelectionChange((selected as string) || undefined)}
                        placeholder="None"
                    >
                        <Option value="">None</Option>
                        {options.map(secret => (
                            <Option key={secret.name} value={secret.name}>{secret.name}</Option>
                        ))}
                    </Select>
                    <Button
                        variant="outlined"
                        size="sm"
                        onClick={() => setQuickCreateType(secretType)}
                    >
                        + New
                    </Button>
                </Box>
            </FormControl>
        );
    }

    return (
        <>
        <Modal open={open} onClose={onClose}>
            <ModalDialog data-id="configure-secrets-modal" sx={{ minWidth: 480, maxWidth: 640, overflowY: 'auto', overflowX: 'hidden' }}>
                <DialogTitle>Configure Secrets</DialogTitle>
                <DialogContent>
                    {fields.includes('s3') && renderSecretSelector(
                        'S3 Credentials',
                        s3Secrets,
                        working.s3Key,
                        next => setWorking(prev => ({ ...prev, s3Key: next })),
                        's3-credentials',
                    )}

                    {fields.includes('encryption') && renderSecretSelector(
                        'Encryption Key',
                        encryptionSecrets,
                        working.encryptionKey,
                        next => setWorking(prev => ({ ...prev, encryptionKey: next })),
                        'encryption-key',
                    )}

                    {fields.includes('geocoding') && renderSecretSelector(
                        'Geocoding API Key',
                        geocodingSecrets,
                        working.geocodingKey,
                        next => setWorking(prev => ({ ...prev, geocodingKey: next })),
                        'api-key',
                    )}
                </DialogContent>
                <DialogActions>
                    <Button variant="plain" onClick={onClose}>Cancel</Button>
                    <Button onClick={() => onSave(working)}>Save</Button>
                </DialogActions>
            </ModalDialog>
        </Modal>
        {quickCreateType !== undefined && (
            <CreateSecretDialog
                open={true}
                secretType={quickCreateType}
                defaultName={quickCreateDefaultName ?? ''}
                onClose={() => setQuickCreateType(undefined)}
                onSave={newSecret => handleQuickCreateSave(newSecret).catch(err => log.exception('Quick-create error:', err as Error))}
            />
        )}
        </>
    );
}
