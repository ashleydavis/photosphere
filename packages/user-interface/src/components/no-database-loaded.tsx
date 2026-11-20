import { log } from "utils";
import { useEffect, useState } from "react";
import Box from "@mui/material/Box";
import CircularProgress from "@mui/material/CircularProgress";
import Typography from "@mui/material/Typography";
import Button from "@mui/material/Button";
import CreateNewFolderIcon from "@mui/icons-material/CreateNewFolder";
import FolderOpenIcon from "@mui/icons-material/FolderOpen";
import AddIcon from "@mui/icons-material/Add";
import PhotoLibraryIcon from "@mui/icons-material/PhotoLibrary";
import { CreateDatabaseModal } from "./create-database-modal";
import { OpenDatabaseModal } from "./open-database-modal";
import { AddDatabaseModal } from "./add-database-modal";
import { usePlatform, type IDatabaseEntry } from "../context/platform-context";
import { useAssetDatabase } from "../context/asset-database-source";
import { useIsMobile } from "../lib/use-is-mobile";

//
// Displayed when no database is loaded, with prompts to create or open one,
// plus a list of recently opened databases for quick access.
//
export function NoDatabaseLoaded() {
    const platform = usePlatform();
    const { openDatabase, isOpening } = useAssetDatabase();

    // Drives the mobile layout: stacked full-width actions rather than a row of three.
    const isMobile = useIsMobile();

    // The path of the recent database the user tapped, so the spinner shows on that one alone.
    const [openingPath, setOpeningPath] = useState<string | undefined>(undefined);

    const [createModalOpen, setCreateModalOpen] = useState(false);
    const [openModalOpen, setOpenModalOpen] = useState(false);
    const [addModalOpen, setAddModalOpen] = useState(false);

    // Recently opened database entries (top 5).
    const [recentDatabases, setRecentDatabases] = useState<IDatabaseEntry[]>([]);

    useEffect(() => {
        platform.getRecentDatabases()
            .then(recent => setRecentDatabases(recent))
            .catch(err => log.exception('Failed to load recent databases:', err as Error));
    }, [platform]);

    return (
        <>
            {/* The app's first screen. On a mobile it is laid out as an onboarding screen: a large
                icon, the pitch, then one full-width primary action with the alternatives under it.
                Three side-by-side buttons is a desktop shape, and at mobile width it clipped the
                outer two off both edges of the screen. */}
            <Box
                data-id="no-database-loaded"
                sx={{
                    display: 'flex',
                    alignItems: 'center',
                    justifyContent: 'center',
                    height: "calc(100vh - 60px)",
                    px: isMobile ? 3 : 0,
                }}
            >
                <Box sx={{ textAlign: 'center', width: '100%', maxWidth: 420 }}>
                    <Box
                        sx={{
                            display: 'inline-flex',
                            alignItems: 'center',
                            justifyContent: 'center',
                            width: isMobile ? 96 : 80,
                            height: isMobile ? 96 : 80,
                            borderRadius: '50%',
                            backgroundColor: 'action.selected',
                            mb: 2.5,
                        }}
                        >
                        <PhotoLibraryIcon sx={{ fontSize: isMobile ? 48 : 40, color: 'text.secondary' }} />
                    </Box>

                    <Typography variant={isMobile ? 'h2' : 'h4'} sx={{ fontSize: isMobile ? '1.9rem' : undefined, mb: 1.5 }}>
                        Welcome to Photosphere
                    </Typography>
                    <Typography variant="body1" sx={{ mb: 4, color: 'text.secondary' }}>
                        Manage your own database of photos and videos. Create a new database, or open one
                        you already have.
                    </Typography>

                    <Box sx={{ display: 'flex', flexDirection: 'column', gap: 1.5 }}>
                        <Button
                            data-id="no-database-new-database"
                            variant="contained"
                            color="primary"
                            size="large"
                            startIcon={<CreateNewFolderIcon />}
                            onClick={() => setCreateModalOpen(true)}
                            sx={{
                                minHeight: 52,
                                borderRadius: 2,
                            }}
                        >
                            New database
                        </Button>
                        <Button
                            data-id="no-database-open-database"
                            variant="outlined"
                            color="inherit"
                            size="large"
                            startIcon={<FolderOpenIcon />}
                            onClick={() => setOpenModalOpen(true)}
                            sx={{
                                minHeight: 52,
                                borderRadius: 2,
                            }}
                        >
                            Open database
                        </Button>
                        <Button
                            data-id="no-database-add-database"
                            variant="outlined"
                            color="inherit"
                            size="large"
                            startIcon={<AddIcon />}
                            onClick={() => setAddModalOpen(true)}
                            sx={{
                                minHeight: 52,
                                borderRadius: 2,
                            }}
                        >
                            Add database
                        </Button>
                    </Box>

                    {recentDatabases.length > 0 && (
                        <Box sx={{ mt: 4, textAlign: 'left' }}>
                            <Typography
                                variant="caption"
                                sx={{
                                    display: 'block',
                                    mb: 1,
                                    color: 'text.secondary',
                                    textTransform: 'uppercase',
                                    letterSpacing: '0.06em',
                                }}
                                >
                                Recent databases
                            </Typography>
                            <Box sx={{ display: 'flex', flexDirection: 'column', gap: 1 }}>
                                {recentDatabases.map((dbEntry, index) => (
                                    <Button
                                        key={dbEntry.name}
                                        data-id={`recent-database-button-${index}`}
                                        variant="outlined"
                                        color="inherit"
                                        size="large"
                                        // Every entry goes dead while an open is under way, so a
                                        // second open cannot be started on top of the first.
                                        disabled={isOpening}
                                        startIcon={<FolderOpenIcon />}
                                        endIcon={isOpening && openingPath === dbEntry.path
                                            ? <CircularProgress data-id={`recent-database-spinner-${index}`} size={24} />
                                            : undefined
                                        }
                                        onClick={() => {
                                            setOpeningPath(dbEntry.path);
                                            openDatabase(dbEntry.path).catch(err => log.exception('Open database error:', err as Error));
                                        }}
                                        sx={{
                                            justifyContent: 'flex-start',
                                            minHeight: 52,
                                            borderRadius: 2,
                                        }}
                                    >
                                        {dbEntry.name || dbEntry.path.split(/[\\/]/).filter(Boolean).pop() || dbEntry.path}
                                    </Button>
                                ))}
                            </Box>
                        </Box>
                    )}
                </Box>
            </Box>

            <CreateDatabaseModal
                open={createModalOpen}
                onClose={() => setCreateModalOpen(false)}
            />

            <OpenDatabaseModal
                open={openModalOpen}
                onClose={() => setOpenModalOpen(false)}
            />

            <AddDatabaseModal
                open={addModalOpen}
                onClose={() => setAddModalOpen(false)}
            />
        </>
    );
}
