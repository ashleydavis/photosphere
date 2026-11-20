import { log } from "utils";
import { useEffect, useState } from "react";
import Box from "@mui/material/Box";
import CircularProgress from "@mui/material/CircularProgress";
import Typography from "@mui/material/Typography";
import Button from "@mui/material/Button";
import ListItemButton from "@mui/material/ListItemButton";
import ChevronRightIcon from "@mui/icons-material/ChevronRight";
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

    // Drives the mobile layout: stacked full-width actions rather than a row of three, and a
    // smaller heading.
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
                    height: "100%",
                    overflowY: "auto",
                    background: "var(--welcome-bg)",
                }}
            >
                <Box
                    sx={{
                        display: "flex",
                        flexDirection: "column",
                        alignItems: "center",
                        justifyContent: "center",
                        textAlign: "center",
                        gap: "var(--space-4)",
                        minHeight: "100%",
                        maxWidth: "calc(var(--space-8) * 20)",
                        marginInline: "auto",
                        padding: isMobile ? "var(--space-6) var(--space-4)" : "var(--space-8) var(--space-6)",
                    }}
                >
                    {/* The logo mark: the app's photos icon on the brand gradient, with a soft halo of
                        the same colours behind it. */}
                    <Box
                        aria-hidden={true}
                        sx={{
                            position: "relative",
                            display: "flex",
                            alignItems: "center",
                            justifyContent: "center",
                            width: "calc(var(--space-8) * 3)",
                            height: "calc(var(--space-8) * 3)",
                        }}
                        >
                        <Box
                            sx={{
                                position: "absolute",
                                inset: "calc(var(--space-2) * -1)",
                                borderRadius: "var(--radius-full)",
                                background: "conic-gradient(from 0deg, var(--brand-purple), var(--brand-rose), var(--brand-amber), var(--brand-purple))",
                                filter: "blur(var(--space-4))",
                                opacity: "var(--welcome-logo-glow-opacity)",
                            }}
                            />
                        <Box
                            sx={{
                                position: "relative",
                                display: "flex",
                                alignItems: "center",
                                justifyContent: "center",
                                width: "calc(var(--space-8) * 2.5)",
                                height: "calc(var(--space-8) * 2.5)",
                                borderRadius: "var(--welcome-logo-radius)",
                                background: "var(--welcome-logo-fill)",
                                boxShadow: "inset 0 0 0 1px var(--white-30), var(--shadow-overlay)",
                                color: "var(--color-empty-icon)",
                            }}
                            >
                            <PhotoLibraryIcon
                                sx={{
                                    fontSize: "var(--space-8)",
                                }}
                                />
                        </Box>
                    </Box>

                    <Box>
                        <Typography
                            component="h2"
                            sx={{
                                fontFamily: "var(--font-heading)",
                                fontSize: isMobile ? "var(--text-xl)" : "var(--text-2xl)",
                                fontWeight: "var(--weight-bold)",
                                lineHeight: "var(--leading-tight)",
                            }}
                            >
                            Welcome to Photosphere
                        </Typography>
                        <Typography
                            sx={{
                                marginTop: "var(--space-2)",
                                color: "var(--color-text-muted)",
                            }}
                            >
                            Manage your own database of photos and videos. Create a new database, or open one
                            you already have.
                        </Typography>
                    </Box>

                    <Box
                        sx={{
                            display: "flex",
                            flexDirection: isMobile ? "column" : "row",
                            flexWrap: "wrap",
                            justifyContent: "center",
                            gap: "var(--space-2)",
                            width: "100%",
                            marginTop: "var(--space-2)",
                        }}
                        >
                        <Button
                            data-id="no-database-new-database"
                            variant="contained"
                            color="primary"
                            size="large"
                            startIcon={<CreateNewFolderIcon />}
                            onClick={() => setCreateModalOpen(true)}
                            fullWidth={isMobile}
                        >
                            New database
                        </Button>
                        <Button
                            data-id="no-database-open-database"
                            variant="outlined"
                            size="large"
                            startIcon={<FolderOpenIcon />}
                            onClick={() => setOpenModalOpen(true)}
                            fullWidth={isMobile}
                        >
                            Open database
                        </Button>
                        <Button
                            data-id="no-database-add-database"
                            variant="outlined"
                            size="large"
                            startIcon={<AddIcon />}
                            onClick={() => setAddModalOpen(true)}
                            fullWidth={isMobile}
                        >
                            Add database
                        </Button>
                    </Box>

                    {recentDatabases.length > 0 && (
                        <Box
                            component="section"
                            sx={{
                                display: "flex",
                                flexDirection: "column",
                                width: "100%",
                                marginTop: "var(--space-4)",
                                textAlign: "left",
                                background: "var(--color-panel)",
                                border: "1px solid var(--color-border)",
                                borderRadius: "var(--radius-md)",
                                boxShadow: "var(--shadow-raised)",
                                overflow: "hidden",
                            }}
                            >
                            <Typography
                                sx={{
                                    padding: "var(--space-3) var(--space-4) var(--space-2)",
                                    fontSize: "var(--text-sm)",
                                    fontWeight: "var(--weight-bold)",
                                    color: "var(--color-text-muted)",
                                }}
                                >
                                Recent databases
                            </Typography>
                            <Box
                                sx={{
                                    display: "flex",
                                    flexDirection: "column",
                                    gap: "var(--space-1)",
                                    padding: "0 var(--space-2) var(--space-2)",
                                }}
                                >
                                {recentDatabases.map((dbEntry, index) => (
                                    <ListItemButton
                                        key={dbEntry.name}
                                        data-id={`recent-database-button-${index}`}
                                        // Every entry goes dead while an open is under way, so a
                                        // second open cannot be started on top of the first.
                                        disabled={isOpening}
                                        onClick={() => {
                                            setOpeningPath(dbEntry.path);
                                            openDatabase(dbEntry.path).catch(err => log.exception('Open database error:', err as Error));
                                        }}
                                        sx={{
                                            gap: "var(--space-3)",
                                            padding: "var(--space-2)",
                                            borderRadius: "var(--radius-sm)",
                                        }}
                                    >
                                        <Box
                                            component="span"
                                            sx={{
                                                display: "flex",
                                                alignItems: "center",
                                                justifyContent: "center",
                                                flex: "none",
                                                width: "var(--button-height-md)",
                                                height: "var(--button-height-md)",
                                                borderRadius: "var(--radius-sm)",
                                                background: "var(--color-chip-bg)",
                                                color: "var(--color-chip-text)",
                                            }}
                                            >
                                            <FolderOpenIcon
                                                sx={{
                                                    fontSize: "var(--icon-lg)",
                                                }}
                                                />
                                        </Box>
                                        <Box
                                            component="span"
                                            sx={{
                                                flex: 1,
                                                minWidth: 0,
                                                overflow: "hidden",
                                                textOverflow: "ellipsis",
                                                whiteSpace: "nowrap",
                                                fontWeight: "var(--weight-bold)",
                                                color: "var(--color-text)",
                                            }}
                                            >
                                            {dbEntry.name || dbEntry.path.split(/[\\/]/).filter(Boolean).pop() || dbEntry.path}
                                        </Box>
                                        <Box
                                            component="span"
                                            sx={{
                                                display: "flex",
                                                alignItems: "center",
                                                justifyContent: "center",
                                                flex: "none",
                                                width: "var(--icon-lg)",
                                                color: "var(--color-text-muted)",
                                            }}
                                            >
                                            {isOpening && openingPath === dbEntry.path
                                                ? <CircularProgress data-id={`recent-database-spinner-${index}`} size="var(--icon-lg)" />
                                                : <ChevronRightIcon
                                                    sx={{
                                                        fontSize: "var(--icon-lg)",
                                                    }}
                                                    />
                                            }
                                        </Box>
                                    </ListItemButton>
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
