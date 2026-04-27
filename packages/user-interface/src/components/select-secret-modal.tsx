import { log } from "utils";
import React, { useEffect, useState } from 'react';
import Modal from '@mui/joy/Modal';
import ModalDialog from '@mui/joy/ModalDialog';
import DialogTitle from '@mui/joy/DialogTitle';
import DialogContent from '@mui/joy/DialogContent';
import DialogActions from '@mui/joy/DialogActions';
import Button from '@mui/joy/Button';
import Table from '@mui/joy/Table';
import Typography from '@mui/joy/Typography';
import { usePlatform, type ISharedSecretEntry } from '../context/platform-context';
import { CreateSecretDialog } from './create-secret-dialog';

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

    // Id of the currently highlighted row.
    const [selectedId, setSelectedId] = useState<string | undefined>(undefined);

    // Whether the inline create dialog is open.
    const [createDialogOpen, setCreateDialogOpen] = useState(false);

    useEffect(() => {
        if (open) {
            setSelectedId(undefined);
            platform.listSecrets()
                .then(allSecrets => setSecrets(allSecrets.filter(secret => secret.type === secretType)))
                .catch(err => log.exception('Failed to load secrets:', err as Error));
        }
    }, [open, platform, secretType]);

    //
    // Calls onSelect with the chosen entry and closes the modal.
    //
    function handleSelect(): void {
        const chosen = secrets.find(secret => secret.id === selectedId);
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
        setSelectedId(newSecret.id);
        onSelect(newSecret);
    }

    return (
        <>
            <Modal open={open} onClose={onClose}>
                <ModalDialog sx={{ minWidth: 480, maxWidth: 700, overflowY: 'auto' }}>
                    <DialogTitle>Select {secretType}</DialogTitle>
                    <DialogContent>
                        {secrets.length === 0
                            ? (
                                <Typography level="body-sm">
                                    No {secretType} secrets configured yet.
                                </Typography>
                            )
                            : (
                                <Table>
                                    <thead>
                                        <tr>
                                            <th>Name</th>
                                            <th style={{ width: '80px' }}></th>
                                        </tr>
                                    </thead>
                                    <tbody>
                                        {secrets.map(secret => (
                                            <tr
                                                key={secret.id}
                                                onClick={() => setSelectedId(secret.id)}
                                                style={{
                                                    cursor: 'pointer',
                                                    backgroundColor: secret.id === selectedId ? 'rgba(0,0,0,0.08)' : undefined,
                                                }}
                                            >
                                                <td>{secret.name}</td>
                                                <td>
                                                    <Button
                                                        size="sm"
                                                        variant="plain"
                                                        onClick={() => {
                                                            setSelectedId(secret.id);
                                                            onSelect(secret);
                                                        }}
                                                    >
                                                        Select
                                                    </Button>
                                                </td>
                                            </tr>
                                        ))}
                                    </tbody>
                                </Table>
                            )
                        }
                    </DialogContent>
                    <DialogActions>
                        <Button variant="plain" onClick={onClose}>Cancel</Button>
                        <Button
                            variant="outlined"
                            onClick={() => setCreateDialogOpen(true)}
                        >
                            Create new
                        </Button>
                        <Button
                            disabled={selectedId === undefined}
                            onClick={handleSelect}
                        >
                            Select
                        </Button>
                    </DialogActions>
                </ModalDialog>
            </Modal>

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
