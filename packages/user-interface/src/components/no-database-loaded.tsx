import { log } from "utils";
import { useEffect, useState } from "react";
import Box from "@mui/joy/Box";
import Typography from "@mui/joy/Typography";
import Button from "@mui/joy/Button";
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
    const { openDatabase } = useAssetDatabase();

    // Drives the phone layout: stacked full-width actions rather than a row of three.
    const isMobile = useIsMobile();

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
            {/* The app's first screen. On a phone it is laid out as an onboarding screen: a large
                icon, the pitch, then one full-width primary action with the alternatives under it.
                Three side-by-side buttons is a desktop shape, and at phone width it clipped the
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
                            backgroundColor: 'background.level2',
                            mb: 2.5,
                        }}
                        >
                        <PhotoLibraryIcon sx={{ fontSize: isMobile ? 48 : 40, color: 'text.secondary' }} />
                    </Box>

                    <Typography level={isMobile ? 'h2' : 'h4'} sx={{ fontSize: isMobile ? '1.9rem' : undefined, mb: 1.5 }}>
                        Welcome to Photosphere
                    </Typography>
                    <Typography level="body-md" sx={{ mb: 4, color: 'text.secondary' }}>
                        Manage your own database of photos and videos. Create a new database, or open one
                        you already have.
                    </Typography>

                    <Box sx={{ display: 'flex', flexDirection: 'column', gap: 1.5 }}>
                        <Button
                            variant="solid"
                            color="primary"
                            size="lg"
                            startDecorator={<CreateNewFolderIcon />}
                            onClick={() => setCreateModalOpen(true)}
                            sx={{ minHeight: 52, borderRadius: 'md' }}
                        >
                            New database
                        </Button>
                        <Button
                            variant="soft"
                            color="neutral"
                            size="lg"
                            startDecorator={<FolderOpenIcon />}
                            onClick={() => setOpenModalOpen(true)}
                            sx={{ minHeight: 52, borderRadius: 'md' }}
                        >
                            Open database
                        </Button>
                        <Button
                            variant="soft"
                            color="neutral"
                            size="lg"
                            startDecorator={<AddIcon />}
                            onClick={() => setAddModalOpen(true)}
                            sx={{ minHeight: 52, borderRadius: 'md' }}
                        >
                            Add database
                        </Button>
                    </Box>

                    {recentDatabases.length > 0 && (
                        <Box sx={{ mt: 4, textAlign: 'left' }}>
                            <Typography
                                level="body-xs"
                                sx={{ mb: 1, color: 'text.tertiary', textTransform: 'uppercase', letterSpacing: '0.06em' }}
                                >
                                Recent databases
                            </Typography>
                            <Box sx={{ display: 'flex', flexDirection: 'column', gap: 1 }}>
                                {recentDatabases.map(dbEntry => (
                                    <Button
                                        key={dbEntry.name}
                                        variant="outlined"
                                        color="neutral"
                                        size="lg"
                                        startDecorator={<FolderOpenIcon />}
                                        onClick={() => openDatabase(dbEntry.path).catch(err => log.exception('Open database error:', err as Error))}
                                        sx={{ justifyContent: 'flex-start', minHeight: 52, borderRadius: 'md' }}
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
