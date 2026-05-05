import React, { useEffect, useState } from 'react';
import { log } from 'utils';
import Modal from '@mui/joy/Modal';
import ModalDialog from '@mui/joy/ModalDialog';
import DialogTitle from '@mui/joy/DialogTitle';
import DialogContent from '@mui/joy/DialogContent';
import DialogActions from '@mui/joy/DialogActions';
import Button from '@mui/joy/Button';
import Typography from '@mui/joy/Typography';
import Box from '@mui/joy/Box';
import { type ISharedSecretEntry } from '../context/platform-context';

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
// Labelled read-only field row.
//
function Field({ label, value, multiline }: { label: string; value: string; multiline?: boolean }) {
    return (
        <Box sx={{ mb: 1.5 }}>
            <Typography level="body-sm" sx={{ fontWeight: 'lg', mb: 0.5 }}>{label}</Typography>
            <Box
                component={multiline ? 'pre' : 'div'}
                sx={{
                    fontFamily: 'monospace',
                    fontSize: '0.85rem',
                    background: 'var(--joy-palette-background-level1)',
                    borderRadius: 'sm',
                    p: 1,
                    whiteSpace: 'pre-wrap',
                    wordBreak: 'break-all',
                }}
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

    //
    // Fetches and reveals the secret value.
    //
    async function handleReveal(): Promise<void> {
        setLoading(true);
        const value = await getSecretValue(secret.name);
        setSecretValue(value);
        setRevealed(true);
        setLoading(false);
        log.info('Secret revealed');
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
                    <Field label="Endpoint" value={parsed?.endpoint ?? ''} />
                    <Field label="Region" value={parsed?.region ?? ''} />
                    <Field label="Access Key ID" value={parsed?.accessKeyId ?? ''} />
                    <Field label="Secret Access Key" value={parsed?.secretAccessKey ?? ''} />
                </>
            );
        }
        if (secret.type === 'encryption-key') {
            return <Field label="Private Key PEM" value={parsed?.privateKeyPem ?? secretValue} multiline />;
        }
        return <Field label="API Key" value={parsed?.apiKey ?? secretValue} />;
    }

    return (
        <Modal open={open} onClose={onClose}>
            <ModalDialog sx={{ minWidth: 480, maxWidth: 680 }}>
                <DialogTitle>View Secret</DialogTitle>
                <DialogContent>
                    <Typography level="body-md" sx={{ mb: 1 }}>
                        <strong>Name:</strong> {secret.name}
                    </Typography>
                    <Typography level="body-md" sx={{ mb: 2 }}>
                        <strong>Type:</strong> {secret.type}
                    </Typography>
                    {!revealed
                        ? (
                            <Typography sx={{ fontFamily: 'monospace', letterSpacing: '0.1em' }}>
                                ••••••••••
                            </Typography>
                        )
                        : renderRevealedFields()
                    }
                </DialogContent>
                <DialogActions>
                    <Button variant="plain" onClick={onClose}>Close</Button>
                    {!revealed && (
                        <Button
                            data-id="reveal-secret-button"
                            loading={loading}
                            disabled={loading}
                            onClick={() => handleReveal().catch(err => log.exception('Reveal error:', err as Error))}
                        >
                            Reveal
                        </Button>
                    )}
                </DialogActions>
            </ModalDialog>
        </Modal>
    );
}
