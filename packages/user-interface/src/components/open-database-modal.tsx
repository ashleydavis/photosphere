import { useEffect, useState } from 'react';
import Modal from '@mui/joy/Modal';
import ModalDialog from '@mui/joy/ModalDialog';
import DialogTitle from '@mui/joy/DialogTitle';
import DialogContent from '@mui/joy/DialogContent';
import DialogActions from '@mui/joy/DialogActions';
import Button from '@mui/joy/Button';
import Box from '@mui/joy/Box';
import Typography from '@mui/joy/Typography';
import FolderOpenIcon from '@mui/icons-material/FolderOpen';
import FolderIcon from '@mui/icons-material/Folder';
import { useNavigate } from 'react-router-dom';
import { usePlatform, type IDatabaseEntry } from '../context/platform-context';
import { useAssetDatabase } from '../context/asset-database-source';
import { AddDatabaseModal } from './add-database-modal';

export interface IOpenDatabaseModalProps {
    // Whether the modal is visible.
    open: boolean;

    // Called when the modal should close.
    onClose: () => void;
}

//
// Modal for selecting and opening a configured database from the known database list.
//
export function OpenDatabaseModal({ open, onClose }: IOpenDatabaseModalProps) {
    const platform = usePlatform();
    const { openDatabase, databasePath } = useAssetDatabase();
    const navigate = useNavigate();

    // All configured database entries.
    const [databases, setDatabases] = useState<IDatabaseEntry[]>([]);

    // Whether the AddDatabaseModal is open.
    const [addModalOpen, setAddModalOpen] = useState(false);

    useEffect(() => {
        if (open) {
            platform.getDatabases()
                .then(entries => setDatabases(entries))
                .catch(err => console.error('Failed to load databases:', err));
        }
    }, [open, platform]);

    //
    // Navigates to the databases management page and closes the modal.
    //
    function handleManageDatabases(): void {
        navigate('/databases');
        onClose();
    }

    return (
        <>
            <Modal open={open} onClose={onClose}>
                <ModalDialog sx={{ minWidth: 560, maxWidth: 800, overflowY: 'auto' }}>
                    <DialogTitle>Open Database</DialogTitle>
                    <DialogContent>
                        {databases.length === 0
                            ? (
                                <Typography level="body-sm">
                                    No databases configured yet.
                                </Typography>
                            )
                            : (
                                <Box sx={{ display: 'flex', flexDirection: 'column', gap: 0.5 }}>
                                    {databases.map(dbEntry => (
                                        <Button
                                            key={dbEntry.id}
                                            variant={dbEntry.path === databasePath ? 'soft' : 'outlined'}
                                            color="neutral"
                                            startDecorator={dbEntry.path === databasePath ? <FolderOpenIcon /> : <FolderIcon />}
                                            onClick={() => openDatabase(dbEntry.path).then(onClose).catch(err => console.error('Open database error:', err))}
                                            sx={{ justifyContent: 'flex-start' }}
                                        >
                                            {dbEntry.name || dbEntry.path.split(/[\\/]/).filter(Boolean).pop()}
                                            <Typography level="body-xs" sx={{ ml: 1, opacity: 0.6 }}>
                                                {dbEntry.path}
                                            </Typography>
                                        </Button>
                                    ))}
                                </Box>
                            )
                        }
                    </DialogContent>
                    <DialogActions>
                        <Button variant="plain" onClick={onClose}>Cancel</Button>
                        <Button
                            variant="outlined"
                            onClick={() => setAddModalOpen(true)}
                        >
                            Add database
                        </Button>
                        <Button
                            variant="outlined"
                            onClick={handleManageDatabases}
                        >
                            Manage databases
                        </Button>
                    </DialogActions>
                </ModalDialog>
            </Modal>

            <AddDatabaseModal
                open={addModalOpen}
                onClose={() => {
                    setAddModalOpen(false);
                    onClose();
                }}
            />
        </>
    );
}
