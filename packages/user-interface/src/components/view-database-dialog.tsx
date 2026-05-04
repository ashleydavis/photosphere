import React, { useState } from 'react';
import { log } from 'utils';
import Modal from '@mui/joy/Modal';
import ModalClose from '@mui/joy/ModalClose';
import ModalDialog from '@mui/joy/ModalDialog';
import DialogTitle from '@mui/joy/DialogTitle';
import DialogContent from '@mui/joy/DialogContent';
import DialogActions from '@mui/joy/DialogActions';
import Button from '@mui/joy/Button';
import Typography from '@mui/joy/Typography';
import Box from '@mui/joy/Box';
import { type IDatabaseEntry, type ISharedSecretEntry } from '../context/platform-context';
import { ViewSecretDialog } from './view-secret-dialog';

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
function InfoRow({ label, value }: { label: string; value: string }) {
    return (
        <Typography level="body-md" sx={{ mb: 1 }}>
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
    function renderLinkedSecret(label: string, secretId: string | undefined, buttonDataId: string): React.ReactNode {
        const found = secretId !== undefined ? allSecrets.find(secret => secret.id === secretId) : undefined;
        return (
            <Box sx={{ display: 'flex', alignItems: 'center', gap: 1, mb: 1 }}>
                <Typography level="body-md" sx={{ minWidth: 160 }}>
                    <strong>{label}:</strong>
                </Typography>
                {found !== undefined
                    ? (
                        <>
                            <Typography level="body-md" sx={{ flexGrow: 1 }}>{found.name}</Typography>
                            <Button
                                data-id={buttonDataId}
                                variant="outlined"
                                size="sm"
                                onClick={() => { log.info('View secret dialog opened'); setViewingSecret(found); }}
                            >
                                View Secret
                            </Button>
                        </>
                    )
                    : (
                        <Typography level="body-md" color="neutral">None</Typography>
                    )
                }
            </Box>
        );
    }

    return (
        <>
            <Modal open={open} onClose={onClose}>
                <ModalDialog sx={{ minWidth: 480, maxWidth: 680 }}>
                    <ModalClose />
                    <DialogTitle>View Database</DialogTitle>
                    <DialogContent>
                        <InfoRow label="Name" value={entry.name} />
                        <InfoRow label="Description" value={entry.description} />
                        <InfoRow label="Path" value={entry.path} />
                        <InfoRow label="Origin" value={entry.origin ?? ''} />

                        <Typography level="title-sm" sx={{ mt: 2, mb: 1 }}>Linked Secrets</Typography>

                        {renderLinkedSecret('S3 Credentials', entry.s3Key, 'view-secret-s3-button')}
                        {renderLinkedSecret('Encryption Key', entry.encryptionKey, 'view-secret-encryption-button')}
                        {renderLinkedSecret('Geocoding API Key', entry.geocodingKey, 'view-secret-geocoding-button')}
                    </DialogContent>
                    <DialogActions>
                        <Button variant="plain" onClick={onClose}>Close</Button>
                    </DialogActions>
                </ModalDialog>
            </Modal>

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
