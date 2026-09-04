import { useEffect, useState } from 'react';
import React from 'react';
import { log } from 'utils';
import { ResponsiveDialog } from './responsive-dialog';
import DialogTitle from '@mui/joy/DialogTitle';
import DialogContent from '@mui/joy/DialogContent';
import DialogActions from '@mui/joy/DialogActions';
import Button from '@mui/joy/Button';
import Box from '@mui/joy/Box';
import CircularProgress from '@mui/joy/CircularProgress';
import Typography from '@mui/joy/Typography';
import FolderOpenIcon from '@mui/icons-material/FolderOpen';
import FolderIcon from '@mui/icons-material/Folder';
import RefreshIcon from '@mui/icons-material/Refresh';
import IconButton from '@mui/joy/IconButton';
import { useNavigate } from 'react-router-dom';
import { useApp } from '../context/app-context';
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
    // The list comes from the app context rather than a read of its own. The context holds it in
    // memory and re-reads it whenever the platform says the configured databases changed, so a
    // database created while this dialog is showing (automatic import creates one on a phone)
    // appears in the list instead of the dialog having to be closed and opened again.
    const { dbs, refreshDbs } = useApp();
    const { openDatabase, databasePath, isOpening } = useAssetDatabase();
    const navigate = useNavigate();

    // Whether the AddDatabaseModal is open.
    const [addModalOpen, setAddModalOpen] = useState(false);

    // Whether a refresh is in progress (drives the spin animation).
    const [refreshing, setRefreshing] = useState(false);

    // Whether the configured databases have finished loading for the current open session. Drives the
    // "Open database dialog opened" log so it only fires once the list has rendered (test automation
    // waits for that log before clicking a list item).
    const [loaded, setLoaded] = useState(false);

    // The path of the entry the user tapped, so the spinner shows on that one rather than on all of
    // them. Which entry is opening is this dialog's own business; that an open is under way at all is
    // the asset database's, and comes from isOpening.
    const [openingPath, setOpeningPath] = useState<string | undefined>(undefined);

    //
    // Reloads databases with a minimum delay so the spin animation is visible.
    //
    async function handleRefresh(): Promise<void> {
        setRefreshing(true);
        await Promise.all([
            refreshDbs(),
            new Promise(resolve => setTimeout(resolve, 500)),
        ]);
        setRefreshing(false);
    }

    //
    // Opens the tapped database, closing the dialog once the open has resolved. The dialog is held
    // open for the whole of it deliberately: closing on the tap leaves the user looking at whatever
    // was behind it with nothing saying anything is happening.
    //
    function handleOpen(dbPath: string): void {
        setOpeningPath(dbPath);
        openDatabase(dbPath)
            .then(onClose)
            .catch(err => log.exception('Open database error:', err as Error));
    }

    // The list is already in memory, but it is re-read as the dialog opens so what is shown is what
    // is on disk right now, and the "opened" log below waits on that read. Nothing here stores the
    // result: the context does that, and the render reads it from there.
    useEffect(() => {
        if (open) {
            setLoaded(false);
            setOpeningPath(undefined);
            refreshDbs()
                .then(() => setLoaded(true))
                .catch(err => log.exception('Failed to load databases:', err as Error));
        }
    }, [open]);

    //
    // Logs the "opened" signal only after the databases have loaded and the list has committed to the
    // DOM, so test automation that waits for this log reliably finds the rendered list items.
    //
    useEffect(() => {
        if (open && loaded) {
            log.info('Open database dialog opened');
        }
    }, [open, loaded]);

    //
    // Navigates to the databases management page and closes the modal.
    //
    function handleManageDatabases(): void {
        navigate('/databases');
        onClose();
    }

    return (
        <>
            <ResponsiveDialog
                open={open}
                onClose={onClose}
                minWidth={560}
                maxWidth={800}
                >
                    <DialogTitle>Open Database</DialogTitle>
                    <DialogContent>
                        {dbs.length === 0
                            ? (
                                <Typography data-id="no-databases-configured" level="body-sm">
                                    No databases configured yet.
                                </Typography>
                            )
                            : (
                                <Box sx={{ display: 'flex', flexDirection: 'column', gap: 0.5 }}>
                                    {dbs.map((dbEntry, index) => (
                                        <Button
                                            key={dbEntry.name}
                                            data-id={`database-list-item-${index}`}
                                            variant={dbEntry.path === databasePath ? 'soft' : 'outlined'}
                                            color="neutral"
                                            // Every entry is disabled while an open is under way, not
                                            // just the one tapped: a second open started on top of
                                            // the first cancels its load and leaves the gallery on
                                            // whichever finishes last.
                                            disabled={isOpening}
                                            startDecorator={dbEntry.path === databasePath ? <FolderOpenIcon /> : <FolderIcon />}
                                            endDecorator={isOpening && openingPath === dbEntry.path
                                                ? <CircularProgress data-id={`database-list-item-spinner-${index}`} size="sm" />
                                                : undefined
                                            }
                                            onClick={() => handleOpen(dbEntry.path)}
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
                    {/* The four actions do not fit one row at phone width, so they wrap instead of
                        squeezing until their labels break mid-button. */}
                    <DialogActions sx={{ flexWrap: 'wrap' }}>
                        <Button variant="plain" onClick={onClose}>Cancel</Button>
                        <IconButton
                            variant="outlined"
                            disabled={refreshing}
                            title="Refresh"
                            onClick={() => handleRefresh().catch(err => log.exception('Failed to refresh databases:', err as Error))}
                        >
                            <RefreshIcon
                                sx={refreshing ? {
                                    animation: 'spin 0.8s linear infinite',
                                    '@keyframes spin': {
                                        from: { transform: 'rotate(0deg)' },
                                        to: { transform: 'rotate(360deg)' },
                                    },
                                } : undefined}
                            />
                        </IconButton>
                        <Button
                            variant="outlined"
                            sx={{ whiteSpace: 'nowrap' }}
                            onClick={() => setAddModalOpen(true)}
                        >
                            Add database
                        </Button>
                        <Button
                            variant="outlined"
                            sx={{ whiteSpace: 'nowrap' }}
                            onClick={handleManageDatabases}
                        >
                            Manage databases
                        </Button>
                    </DialogActions>
            </ResponsiveDialog>

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
