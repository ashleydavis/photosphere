import { log } from "utils";
import React, { useEffect, useState } from 'react';
import { ResponsiveDialog } from './responsive-dialog';
import DialogTitle from '@mui/material/DialogTitle';
import DialogContent from '@mui/material/DialogContent';
import DialogActions from '@mui/material/DialogActions';
import Button from '@mui/material/Button';
import Table from '@mui/material/Table';
import TableHead from '@mui/material/TableHead';
import TableBody from '@mui/material/TableBody';
import TableRow from '@mui/material/TableRow';
import TableCell from '@mui/material/TableCell';
import Typography from '@mui/material/Typography';
import { usePlatform, type ISharedSecretEntry } from '../context/platform-context';
import { CreateSecretDialog } from './create-secret-dialog';
import { createDialogKeyHandler } from '../lib/dialog-keys';

export interface ISelectSecretModalProps {
    // Whether the modal is visible.
    open: boolean;

    // The type of secrets to list (e.g. 's3-credentials', 'encryption-key', 'api-key').
    secretType: string;

    // Called when the modal should close without a selection.
    onClose: () => void;

    // Called with the chosen secret entry when the user selects one.
    onSelect: (secret: ISharedSecretEntry) => void;
}

//
// Modal for selecting an existing shared secret or creating a new one inline.
//
export function SelectSecretModal({ open, secretType, onClose, onSelect }: ISelectSecretModalProps) {
    const platform = usePlatform();

    // Secrets matching the requested type.
    const [secrets, setSecrets] = useState<ISharedSecretEntry[]>([]);

    // Name of the currently highlighted row.
    const [selectedName, setSelectedName] = useState<string | undefined>(undefined);

    // Whether the inline create dialog is open.
    const [createDialogOpen, setCreateDialogOpen] = useState(false);

    useEffect(() => {
        if (open) {
            setSelectedName(undefined);
            platform.listSecrets()
                .then(allSecrets => {
                    setSecrets(allSecrets.filter(secret => secret.type === secretType));
                    log.info('Select secret modal ready');
                })
                .catch(err => log.exception('Failed to load secrets:', err as Error));
        }
    }, [open, platform, secretType]);

    //
    // Calls onSelect with the chosen entry and closes the modal.
    //
    function handleSelect(): void {
        const chosen = secrets.find(secret => secret.name === selectedName);
        if (chosen) {
            onSelect(chosen);
        }
    }

    //
    // Handles a newly created secret: refresh list and auto-select it.
    //
    async function handleCreated(newSecret: ISharedSecretEntry): Promise<void> {
        setCreateDialogOpen(false);
        const allSecrets = await platform.listSecrets();
        setSecrets(allSecrets.filter(secret => secret.type === secretType));
        setSelectedName(newSecret.name);
        onSelect(newSecret);
    }

    return (
        <>
            <ResponsiveDialog
                open={open}
                onClose={onClose}
                minWidth={480}
                maxWidth={700}
                onKeyDown={createDialogKeyHandler(handleSelect, selectedName === undefined)}
                >
                <DialogTitle>Select {secretType}</DialogTitle>
                <DialogContent>
                    {secrets.length === 0
                        ? (
                            <Typography variant="body2">
                                No {secretType} secrets configured yet.
                            </Typography>
                        )
                        : (
                            <Table size="small">
                                <TableHead>
                                    <TableRow>
                                        <TableCell>Name</TableCell>
                                        <TableCell sx={{ width: '80px' }}></TableCell>
                                    </TableRow>
                                </TableHead>
                                <TableBody>
                                    {secrets.map(secret => (
                                        <TableRow
                                            key={secret.name}
                                            onClick={() => setSelectedName(secret.name)}
                                            selected={secret.name === selectedName}
                                            sx={{ cursor: 'pointer' }}
                                        >
                                            <TableCell>{secret.name}</TableCell>
                                            <TableCell>
                                                <Button
                                                    data-id="secret-select-button"
                                                    size="small"
                                                    variant="text"
                                                    onClick={() => {
                                                        setSelectedName(secret.name);
                                                        onSelect(secret);
                                                    }}
                                                >
                                                    Select
                                                </Button>
                                            </TableCell>
                                        </TableRow>
                                    ))}
                                </TableBody>
                            </Table>
                        )
                    }
                </DialogContent>
                <DialogActions>
                    <Button variant="text" onClick={onClose}>Cancel</Button>
                    <Button
                        variant="outlined"
                        onClick={() => setCreateDialogOpen(true)}
                    >
                        Create new
                    </Button>
                    <Button
                        variant="contained"
                        disabled={selectedName === undefined}
                        onClick={handleSelect}
                    >
                        Select
                    </Button>
                </DialogActions>
            </ResponsiveDialog>

            {createDialogOpen && (
                <CreateSecretDialog
                    open={true}
                    secretType={secretType}
                    defaultName=""
                    onClose={() => setCreateDialogOpen(false)}
                    onSave={newSecret => handleCreated(newSecret).catch(err => log.exception('Create secret error:', err as Error))}
                />
            )}
        </>
    );
}
