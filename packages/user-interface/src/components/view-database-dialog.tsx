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
import StorageIcon from '@mui/icons-material/Storage';
import { DialogIconBadge } from './dialog-icon-badge';
import { CARD_SX } from './create-database-modal';

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
// A labelled read-only row of the details card: the label muted at the left and the value at the
// right, wrapping below the label on a narrow dialog rather than widening it. `first` leaves off
// the divider above the row, so the card's own edge is the only line above the first row. `mono`
// sets the value in the monospace font, for a path.
//
function InfoRow({ label, value, dataId, first, mono }: { label: string; value: string; dataId: string; first: boolean; mono: boolean }) {
    return (
        <Typography
            data-id={dataId}
            component="div"
            variant="body1"
            sx={{
                display: 'flex',
                flexWrap: 'wrap',
                alignItems: 'baseline',
                justifyContent: 'space-between',
                columnGap: 'var(--space-4)',
                rowGap: 'var(--space-1)',
                padding: 'var(--space-3)',
                borderTop: first ? 'none' : 'var(--settings-row-divider-width) solid var(--color-border)',
            }}
            >
            <Box
                component="span"
                sx={{
                    color: 'var(--color-text-muted)',
                    fontSize: 'var(--text-sm)',
                }}
                >
                {label}:
            </Box>
            {' '}
            <Box
                component="span"
                sx={{
                    minWidth: 0,
                    textAlign: 'right',
                    overflowWrap: 'anywhere',
                    fontFamily: mono ? 'var(--font-mono)' : undefined,
                    fontSize: mono ? 'var(--text-sm)' : undefined,
                }}
                >
                {value}
            </Box>
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
    function renderLinkedSecret(label: string, secretName: string | undefined, buttonDataId: string, first: boolean): React.ReactNode {
        const found = secretName !== undefined ? allSecrets.find(secret => secret.name === secretName) : undefined;
        return (
            <Box
                sx={{
                    display: 'flex',
                    alignItems: 'center',
                    gap: 'var(--space-3)',
                    minHeight: 'calc(var(--space-8) + var(--space-6))',
                    padding: 'var(--space-2) var(--space-3)',
                    borderTop: first ? 'none' : 'var(--settings-row-divider-width) solid var(--color-border)',
                }}
                >
                <Box
                    sx={{
                        display: 'flex',
                        flexDirection: 'column',
                        flexGrow: 1,
                        minWidth: 0,
                    }}
                    >
                    <Typography
                        variant="body1"
                        sx={{
                            color: 'var(--color-text-muted)',
                            fontSize: 'var(--text-sm)',
                        }}
                        >
                        {label}:
                    </Typography>
                    {found !== undefined
                        ? (
                            <Typography
                                data-id={`linked-secret-name-${found.name}`}
                                variant="body1"
                                sx={{
                                    overflowWrap: 'anywhere',
                                }}
                                >
                                {found.name}
                            </Typography>
                        )
                        : (
                            <Typography
                                data-id={`${buttonDataId}-none`}
                                variant="body1"
                                sx={{
                                    color: 'var(--color-text-muted)',
                                }}
                                >
                                None
                            </Typography>
                        )
                    }
                </Box>
                {found !== undefined && (
                    <Button
                        data-id={buttonDataId}
                        variant="outlined"
                        size="small"
                        sx={{
                            flex: 'none',
                        }}
                        onClick={() => { log.info('View secret dialog opened'); setViewingSecret(found); }}
                    >
                        View Secret
                    </Button>
                )}
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
                    sx={{
                        position: 'absolute',
                        top: 'var(--space-4)',
                        right: 'var(--space-6)',
                    }}
                    >
                    <CloseIcon />
                </IconButton>
                <DialogTitle>
                    <DialogIconBadge icon={<StorageIcon />} danger={false} />
                    View Database
                </DialogTitle>
                <DialogContent>
                    <Box
                        sx={{
                            display: 'flex',
                            flexDirection: 'column',
                            gap: 'var(--space-4)',
                            paddingTop: 'var(--space-1)',
                        }}
                        >
                        <Box sx={CARD_SX}>
                            <InfoRow label="Name" value={entry.name} dataId="view-database-name" first={true} mono={false} />
                            <InfoRow label="Description" value={entry.description} dataId="view-database-description" first={false} mono={false} />
                            <InfoRow label="Path" value={entry.path} dataId="view-database-path" first={false} mono={true} />
                            <InfoRow label="Origin" value={entry.origin ?? ''} dataId="view-database-origin" first={false} mono={true} />
                        </Box>

                        <Box
                            sx={{
                                display: 'flex',
                                flexDirection: 'column',
                                gap: 'var(--space-1)',
                            }}
                            >
                            <Typography
                                variant="subtitle2"
                                sx={{
                                    padding: '0 var(--space-3)',
                                    color: 'var(--color-text-muted)',
                                    fontSize: 'var(--text-sm)',
                                    fontWeight: 'var(--weight-bold)',
                                }}
                                >
                                Linked Secrets
                            </Typography>
                            <Box sx={CARD_SX}>
                                {renderLinkedSecret('S3 Credentials', entry.s3Key, 'view-secret-s3-button', true)}
                                {renderLinkedSecret('Encryption Key', entry.encryptionKey, 'view-secret-encryption-button', false)}
                                {renderLinkedSecret('Geocoding API Key', entry.geocodingKey, 'view-secret-geocoding-button', false)}
                            </Box>
                        </Box>
                    </Box>
                </DialogContent>
                <DialogActions>
                    <Button data-id="view-database-close-button" variant="contained" onClick={onClose}>Close</Button>
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
