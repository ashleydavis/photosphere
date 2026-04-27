import { log } from "utils";
import { useEffect, useState } from "react";
import Box from "@mui/joy/Box";
import Typography from "@mui/joy/Typography";
import Button from "@mui/joy/Button";
import CreateNewFolderIcon from "@mui/icons-material/CreateNewFolder";
import FolderOpenIcon from "@mui/icons-material/FolderOpen";
import { CreateDatabaseModal } from "./create-database-modal";
import { OpenDatabaseModal } from "./open-database-modal";
import { usePlatform, type IDatabaseEntry } from "../context/platform-context";
import { useAssetDatabase } from "../context/asset-database-source";

//
// Displayed when no database is loaded, with prompts to create or open one,
// plus a list of recently opened databases for quick access.
//
export function NoDatabaseLoaded() {
    const platform = usePlatform();
    const { openDatabase } = useAssetDatabase();

    const [createModalOpen, setCreateModalOpen] = useState(false);
    const [openModalOpen, setOpenModalOpen] = useState(false);

    // Recently opened database entries (top 5).
    const [recentDatabases, setRecentDatabases] = useState<IDatabaseEntry[]>([]);

    useEffect(() => {
        platform.getRecentDatabases()
            .then(recent => setRecentDatabases(recent))
            .catch(err => log.exception('Failed to load recent databases:', err as Error));
    }, [platform]);

    return (
        <>
            <Box
                className="flex items-center justify-center"
                sx={{
                    height: "calc(100vh - 60px)",
                }}
            >
                <Box sx={{ textAlign: 'center' }}>
                    <Typography level="h4" sx={{ mb: 2 }}>
                        No database loaded
                    </Typography>
                    <Typography level="body-md" sx={{ mb: 4, maxWidth: 400, mx: 'auto' }}>
                        Create a new database or open an existing one.
                    </Typography>
                    <Box sx={{ display: 'flex', gap: 2, justifyContent: 'center' }}>
                        <Button
                            variant="soft"
                            color="neutral"
                            size="lg"
                            startDecorator={<CreateNewFolderIcon />}
                            onClick={() => setCreateModalOpen(true)}
                            sx={{ borderRadius: 's', px: 4 }}
                        >
                            New database
                        </Button>
                        <Button
                            variant="soft"
                            color="neutral"
                            size="lg"
                            startDecorator={<FolderOpenIcon />}
                            onClick={() => setOpenModalOpen(true)}
                            sx={{ borderRadius: 's', px: 4 }}
                        >
                            Open database
                        </Button>
                    </Box>

                    {recentDatabases.length > 0 && (
                        <Box sx={{ mt: 4 }}>
                            <Typography level="title-sm" sx={{ mb: 1 }}>
                                Recent databases
                            </Typography>
                            <Box sx={{ display: 'flex', flexDirection: 'column', gap: 0.5, maxWidth: 400, mx: 'auto' }}>
                                {recentDatabases.map(dbEntry => (
                                    <Button
                                        key={dbEntry.path}
                                        variant="outlined"
                                        color="neutral"
                                        startDecorator={<FolderOpenIcon />}
                                        onClick={() => openDatabase(dbEntry.path).catch(err => log.exception('Open database error:', err as Error))}
                                        sx={{ justifyContent: 'flex-start' }}
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
        </>
    );
}
