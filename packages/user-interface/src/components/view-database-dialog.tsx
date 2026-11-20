import React, { useState } from 'react';
import { log } from 'utils';
import IconButton from '@mui/material/IconButton';
import CloseIcon from '@mui/icons-material/Close';
import DialogTitle from '@mui/material/DialogTitle';
import DialogContent from '@mui/material/DialogContent';
import DialogActions from '@mui/material/DialogActions';
import Button from '@mui/material/Button';
import Typography from '@mui/material/Typography';
import Box from '@mui/material/Box';
import { type IDatabaseEntry, type ISharedSecretEntry } from '../context/platform-context';
import { ViewSecretDialog } from './view-secret-dialog';
import { createDialogKeyHandler } from '../lib/dialog-keys';
import { ResponsiveDialog } from './responsive-dialog';

//
// Props for ViewDatabaseDialog.
//
export interface IViewDatabaseDialogProps {
    // Whether the dialog is open.
    open: boolean;

    // The database entry to display.
    entry: IDatabaseEntry;

    // All known shared secrets (used to resolve linked secret names).
    allSecrets: ISharedSecretEntry[];

    // Called when the dialog should close.
    onClose: () => void;

    // Fetches the raw JSON value string for a given secret id.
    getSecretValue: (id: string) => Promise<string | undefined>;
}

//
// A labelled read-only row rendered inside the dialog content.
//
function InfoRow({ label, value, dataId }: { label: string; value: string; dataId: string }) {
    return (
        <Typography data-id={dataId} variant="body1" sx={{ mb: 1 }}>
            <strong>{label}:</strong> {value}
        </Typography>
    );
}

//
// Dialog that shows a database entry's details and its linked secrets.
//
export function ViewDatabaseDialog({ open, entry, allSecrets, onClose, getSecretValue }: IViewDatabaseDialogProps) {
    // The linked secret currently being viewed in the nested ViewSecretDialog.
    const [viewingSecret, setViewingSecret] = useState<ISharedSecretEntry | undefined>(undefined);

    //
    // Renders one linked-secret row: a label, the secret name (or "None"), and optionally a View button.
    //
    function renderLinkedSecret(label: string, secretName: string | undefined, buttonDataId: string): React.ReactNode {
        const found = secretName !== undefined ? allSecrets.find(secret => secret.name === secretName) : undefined;
        return (
            <Box sx={{ display: 'flex', alignItems: 'center', gap: 1, mb: 1 }}>
                <Typography variant="body1" sx={{ minWidth: 160 }}>
                    <strong>{label}:</strong>
                </Typography>
                {found !== undefined
                    ? (
                        <>
                            <Typography data-id={`linked-secret-name-${found.name}`} variant="body1" sx={{ flexGrow: 1 }}>{found.name}</Typography>
                            <Button
                                data-id={buttonDataId}
                                variant="outlined"
                                size="small"
                                onClick={() => { log.info('View secret dialog opened'); setViewingSecret(found); }}
                            >
                                View Secret
                            </Button>
                        </>
                    )
                    : (
                        <Typography data-id={`${buttonDataId}-none`} variant="body1" color="text.secondary">None</Typography>
                    )
                }
            </Box>
        );
    }

    return (
        <>
            <ResponsiveDialog
                open={open}
                onClose={onClose}
                minWidth={480}
                maxWidth={680}
                onKeyDown={createDialogKeyHandler(onClose, false)}
                >
                <IconButton
                    aria-label="Close"
                    onClick={onClose}
                    sx={{ position: 'absolute', top: 8, right: 8 }}
                    >
                    <CloseIcon />
                </IconButton>
                <DialogTitle>View Database</DialogTitle>
                <DialogContent>
                    <InfoRow label="Name" value={entry.name} dataId="view-database-name" />
                    <InfoRow label="Description" value={entry.description} dataId="view-database-description" />
                    <InfoRow label="Path" value={entry.path} dataId="view-database-path" />
                    <InfoRow label="Origin" value={entry.origin ?? ''} dataId="view-database-origin" />

                    <Typography variant="subtitle2" sx={{ mt: 2, mb: 1 }}>Linked Secrets</Typography>

                    {renderLinkedSecret('S3 Credentials', entry.s3Key, 'view-secret-s3-button')}
                    {renderLinkedSecret('Encryption Key', entry.encryptionKey, 'view-secret-encryption-button')}
                    {renderLinkedSecret('Geocoding API Key', entry.geocodingKey, 'view-secret-geocoding-button')}
                </DialogContent>
                <DialogActions>
                    <Button data-id="view-database-close-button" variant="text" onClick={onClose}>Close</Button>
                </DialogActions>
            </ResponsiveDialog>

            {viewingSecret !== undefined && (
                <ViewSecretDialog
                    open={viewingSecret !== undefined}
                    secret={viewingSecret!}
                    onClose={() => setViewingSecret(undefined)}
                    getSecretValue={getSecretValue}
                />
            )}
        </>
    );
}
