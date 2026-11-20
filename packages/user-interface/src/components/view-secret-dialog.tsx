import React, { useEffect, useState } from 'react';
import { log } from 'utils';
import { ResponsiveDialog } from './responsive-dialog';
import Key from '@mui/icons-material/Key';
import { DialogIconBadge } from './dialog-icon-badge';
import { DetailRows } from './lan-share-parts';
import DialogTitle from '@mui/material/DialogTitle';
import DialogContent from '@mui/material/DialogContent';
import DialogActions from '@mui/material/DialogActions';
import Button from '@mui/material/Button';
import Typography from '@mui/material/Typography';
import Box from '@mui/material/Box';
import { type ISharedSecretEntry } from '../context/platform-context';
import { createDialogKeyHandler } from '../lib/dialog-keys';

//
// Props for ViewSecretDialog.
//
export interface IViewSecretDialogProps {
    // Whether the dialog is open.
    open: boolean;

    // The secret entry to view.
    secret: ISharedSecretEntry;

    // Called when the dialog should close.
    onClose: () => void;

    // Fetches the raw vault value string for the given secret id.
    getSecretValue: (id: string) => Promise<string | undefined>;
}

//
// Possible parsed shape of a vault value (any subset of fields may be present).
//
interface IParsedSecretValue {
    // S3 endpoint (s3-credentials).
    endpoint?: string;

    // S3 region (s3-credentials).
    region?: string;

    // S3 access key id (s3-credentials).
    accessKeyId?: string;

    // S3 secret access key (s3-credentials).
    secretAccessKey?: string;

    // Private key PEM (legacy encryption-key envelope).
    privateKeyPem?: string;

    // API key value (legacy api-key envelope).
    apiKey?: string;
}

//
// Tries to parse a vault value as JSON; returns undefined when the value is a raw string.
//
function tryParse(valueJson: string): IParsedSecretValue | undefined {
    try {
        return JSON.parse(valueJson) as IParsedSecretValue;
    }
    catch {
        return undefined;
    }
}

//
// Props for the labelled read-only field row.
//
interface IFieldProps {
    // The field label shown above the value.
    label: string;

    // The revealed value shown in the field.
    value: string;

    // Whether to render the value as pre-formatted multiline text (used for PEM blocks).
    multiline?: boolean;

    // Optional data-id on the value box so smoke tests can read the revealed value back.
    dataId?: string;
}

//
// The look of a copyable value, such as a revealed key or the dots that hide it: the mono font on
// the --mono-value tokens, wrapping anywhere so a long key never widens the dialog. The revealed
// fields and the hidden value share it, so revealing changes the text and not the box.
//
const MONO_VALUE_SX = {
    margin: 0,
    minHeight: 'var(--button-height-md)',
    padding: 'var(--mono-value-padding)',
    fontFamily: 'var(--font-mono)',
    fontSize: 'var(--text-sm)',
    lineHeight: 'var(--leading-normal)',
    color: 'var(--color-text)',
    backgroundColor: 'var(--mono-value-bg)',
    border: '1px solid var(--mono-value-border-color)',
    borderRadius: 'var(--radius-md)',
    whiteSpace: 'pre-wrap',
    overflowWrap: 'anywhere',
};

//
// Labelled read-only field row.
//
function Field({ label, value, multiline, dataId }: IFieldProps) {
    return (
        <Box
            sx={{
                display: 'flex',
                flexDirection: 'column',
                gap: 'var(--space-1)',
            }}
            >
            <Typography
                variant="body2"
                sx={{
                    color: 'var(--color-text-muted)',
                    fontSize: 'var(--text-sm)',
                }}
                >
                {label}
            </Typography>
            <Box
                data-id={dataId}
                component={multiline ? 'pre' : 'div'}
                sx={MONO_VALUE_SX}
            >
                {value}
            </Box>
        </Box>
    );
}

//
// Dialog that shows a secret's value, initially masked, revealed on demand.
//
export function ViewSecretDialog({ open, secret, onClose, getSecretValue }: IViewSecretDialogProps) {
    // Whether the value has been revealed.
    const [revealed, setRevealed] = useState(false);

    // The fetched raw vault value string.
    const [secretValue, setSecretValue] = useState<string | undefined>(undefined);

    // Whether a fetch is in progress.
    const [loading, setLoading] = useState(false);

    useEffect(() => {
        if (open) {
            setRevealed(false);
            setSecretValue(undefined);
            setLoading(false);
        }
    }, [open]);

    // Log that the value is revealed only once React has committed the revealed fields to the DOM.
    // Logging it straight after setRevealed (the same tick, before the commit) made the line arrive
    // while the fields were still empty, so a smoke test that waits for it and immediately reads a field
    // could read the pre-render value and conclude the secret had been lost.
    useEffect(() => {
        if (revealed) {
            log.info('Secret revealed');
        }
    }, [revealed]);

    //
    // Fetches and reveals the secret value.
    //
    async function handleReveal(): Promise<void> {
        setLoading(true);
        const value = await getSecretValue(secret.name);
        setSecretValue(value);
        setRevealed(true);
        setLoading(false);
    }

    //
    // Renders type-specific labelled fields for the revealed value.
    //
    function renderRevealedFields(): React.ReactNode {
        if (secretValue === undefined) {
            return null;
        }
        const parsed = tryParse(secretValue);
        if (secret.type === 's3-credentials') {
            return (
                <>
                    <Field label="Endpoint" value={parsed?.endpoint ?? ''} dataId="revealed-secret-endpoint" />
                    <Field label="Region" value={parsed?.region ?? ''} dataId="revealed-secret-region" />
                    <Field label="Access Key ID" value={parsed?.accessKeyId ?? ''} dataId="revealed-secret-access-key-id" />
                    <Field label="Secret Access Key" value={parsed?.secretAccessKey ?? ''} dataId="revealed-secret-secret-access-key" />
                </>
            );
        }
        if (secret.type === 'encryption-key') {
            return <Field label="Private Key PEM" value={parsed?.privateKeyPem ?? secretValue} multiline dataId="revealed-secret-private-key-pem" />;
        }
        return <Field label="API Key" value={parsed?.apiKey ?? secretValue} dataId="revealed-secret-api-key" />;
    }

    //
    // The primary action: reveal the value while still hidden, otherwise close.
    //
    async function handleConfirm(): Promise<void> {
        if (!revealed) {
            await handleReveal();
        }
        else {
            onClose();
        }
    }

    return (
        <ResponsiveDialog
            open={open}
            onClose={onClose}
            minWidth={480}
            maxWidth={680}
            onKeyDown={createDialogKeyHandler(handleConfirm, loading)}
            >
                <DialogTitle><DialogIconBadge icon={<Key />} danger={false} />View Secret</DialogTitle>
                <DialogContent
                    sx={{
                        display: 'flex',
                        flexDirection: 'column',
                        gap: 'var(--space-4)',
                    }}
                    >
                    <DetailRows
                        details={[
                            {
                                label: 'Name:',
                                value: secret.name,
                                dataId: 'view-secret-name',
                            },
                            {
                                label: 'Type:',
                                value: secret.type,
                                dataId: 'view-secret-type',
                            },
                        ]}
                        />
                    {!revealed
                        ? (
                            <Typography
                                data-id="hidden-secret-value"
                                sx={{
                                    ...MONO_VALUE_SX,
                                    letterSpacing: 'var(--space-1)',
                                }}
                                >
                                ••••••••••
                            </Typography>
                        )
                        : renderRevealedFields()
                    }
                </DialogContent>
                <DialogActions>
                    <Button data-id="view-secret-close-button" variant="outlined" onClick={onClose}>Close</Button>
                    {!revealed && (
                        <Button
                            data-id="reveal-secret-button"
                            variant="contained"
                            loading={loading}
                            disabled={loading}
                            onClick={() => handleReveal().catch(err => log.exception('Reveal error:', err as Error))}
                        >
                            Reveal
                        </Button>
                    )}
                </DialogActions>
        </ResponsiveDialog>
    );
}
