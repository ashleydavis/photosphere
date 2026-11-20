import React, { useEffect, useState } from 'react';
import Box from '@mui/material/Box';
import Button from '@mui/material/Button';
import DialogActions from '@mui/material/DialogActions';
import DialogContent from '@mui/material/DialogContent';
import DialogTitle from '@mui/material/DialogTitle';
import FormControl from '@mui/material/FormControl';
import FormLabel from '@mui/material/FormLabel';
import { ResponsiveDialog } from './responsive-dialog';
import MenuItem from '@mui/material/MenuItem';
import Select from '@mui/material/Select';
import type { ISharedSecretEntry } from '../context/platform-context';
import { CreateSecretDialog } from './create-secret-dialog';
import { createDialogKeyHandler } from '../lib/dialog-keys';

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
    // Default name suggested by the quick-create dialog (e.g. the database name or path).
    //
    quickCreateDefaultName?: string;

    //
    // Which secret rows to render. Defaults to all three.
    //
    fields?: ConfigureSecretsField[];
}

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

    //
    // Keyed on `open` alone: a caller may build initialValue afresh on every render, and a quick-created secret refreshes the
    // secret lists, which re-renders the caller, so resetting on initialValue would throw away the secret just picked.
    //
    useEffect(() => {
        if (open) {
            setWorking(initialValue);
        }
    // eslint-disable-next-line react-hooks/exhaustive-deps
    }, [open]);

    //
    // Handles the user picking a newly created secret. Auto-selects it for the matching field.
    // The shared-secrets list refreshes through AppContext, so parents do not need notification.
    //
    function handleQuickCreateSave(newSecret: ISharedSecretEntry): void {
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
    }

    //
    // Renders one secret selector row with a dropdown and a "+ New" button. dataIdPrefix names that
    // row's controls, because all three rows come from this one function and would otherwise share a
    // single set of ids.
    //
    function renderSecretSelector(
        label: string,
        options: ISharedSecretEntry[],
        selectedName: string | undefined,
        onSelectionChange: (name: string | undefined) => void,
        secretType: string,
        dataIdPrefix: string,
    ): React.ReactNode {
        const selectDisplayProps: ISelectDisplayProps = {
            'data-id': `${dataIdPrefix}-select`,
        };
        return (
            <FormControl fullWidth sx={{ mb: 1 }}>
                <FormLabel>{label}</FormLabel>
                <Box sx={{ display: 'flex', gap: 1 }}>
                    <Select
                        size="small"
                        sx={{ flexGrow: 1 }}
                        value={selectedName ?? ''}
                        onChange={event => onSelectionChange(event.target.value || undefined)}
                        displayEmpty
                        SelectDisplayProps={selectDisplayProps}
                    >
                        <MenuItem data-id={`${dataIdPrefix}-option-none`} value="">None</MenuItem>
                        {options.map(secret => (
                            <MenuItem data-id={`${dataIdPrefix}-option-${secret.name}`} key={secret.name} value={secret.name}>{secret.name}</MenuItem>
                        ))}
                    </Select>
                    <Button
                        data-id={`${dataIdPrefix}-new-button`}
                        variant="outlined"
                        size="small"
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
        <ResponsiveDialog
            open={open}
            onClose={onClose}
            minWidth={480}
            maxWidth={640}
            dataId="configure-secrets-modal"
            onKeyDown={createDialogKeyHandler(() => onSave(working), false)}
            >
                <DialogTitle>Configure Secrets</DialogTitle>
                <DialogContent>
                    {fields.includes('s3') && renderSecretSelector(
                        'S3 Credentials',
                        s3Secrets,
                        working.s3Key,
                        next => setWorking(prev => ({ ...prev, s3Key: next })),
                        's3-credentials',
                        'configure-secrets-s3',
                    )}

                    {fields.includes('encryption') && renderSecretSelector(
                        'Encryption Key',
                        encryptionSecrets,
                        working.encryptionKey,
                        next => setWorking(prev => ({ ...prev, encryptionKey: next })),
                        'encryption-key',
                        'configure-secrets-encryption',
                    )}

                    {fields.includes('geocoding') && renderSecretSelector(
                        'Geocoding API Key',
                        geocodingSecrets,
                        working.geocodingKey,
                        next => setWorking(prev => ({ ...prev, geocodingKey: next })),
                        'api-key',
                        'configure-secrets-geocoding',
                    )}
                </DialogContent>
                <DialogActions>
                    <Button data-id="configure-secrets-cancel" variant="text" onClick={onClose}>Cancel</Button>
                    <Button data-id="configure-secrets-save" variant="contained" onClick={() => onSave(working)}>Save</Button>
                </DialogActions>
        </ResponsiveDialog>
        {quickCreateType !== undefined && (
            <CreateSecretDialog
                open={true}
                secretType={quickCreateType}
                defaultName={quickCreateDefaultName ?? ''}
                onClose={() => setQuickCreateType(undefined)}
                onSave={newSecret => handleQuickCreateSave(newSecret)}
            />
        )}
        </>
    );
}
