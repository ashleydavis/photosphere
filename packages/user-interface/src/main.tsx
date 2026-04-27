import React, { useEffect, useLayoutEffect, useState } from "react";
import { log } from "utils";
import { Route, Routes, Navigate, useNavigate } from "react-router-dom";
import { GalleryPage } from "./pages/gallery/gallery";
import classNames from "classnames";
import { usePlatform } from "./context/platform-context";
import { useConfig } from "./context/config-context";
import { useAssetDatabase } from "./context/asset-database-source";
import { useSearch } from "./context/search-context";
import { FullscreenSpinner } from "./components/full-screen-spinnner";
import { CssVarsProvider, useColorScheme } from "@mui/joy/styles/CssVarsProvider";
import { useTheme } from "@mui/joy/styles/ThemeProvider";
import Drawer from "@mui/joy/Drawer/Drawer";
import { LeftSidebar } from "./components/left-sidebar";
import { RightSidebar } from "./components/right-sidebar";
import { Navbar } from "./components/navbar";
import { Fps } from "./components/fps";
import { AboutPage } from "./pages/about";
import { MapPage } from "./pages/map/map-page";
import { ConfigurationDialog } from "./components/configuration-dialog";
import { useToast } from "./context/toast-context";
import { ToastContainer } from "./components/toast-container";
import { useImport } from "./context/import-context";
import { ImportPage } from "./pages/import/import-page";
import { DatabasesPage } from "./pages/databases/databases-page";
import { SecretsPage } from "./pages/secrets/secrets-page";
import { OpenDatabaseModal } from "./components/open-database-modal";
import { CreateDatabaseModal } from "./components/create-database-modal";

export interface IMainProps {
    //
    // Set to true if running on mobile device to enable mobile-specific styles.
    //
    isMobile: boolean;

    //
    // Initial theme mode to use before loading from platform.
    //
    initialTheme: 'light' | 'dark' | 'system';
}

//
// The main page of the Photosphere app.
//
function __Main({ isMobile, initialTheme }: IMainProps) {
    const { 
        isWorking,
        databasePath,
        openDatabase,
    } = useAssetDatabase();

    //
    // Set to true to open the left sidebar.
    //
    const [sidebarOpen, setSidebarOpen] = useState<boolean>(false);

    //
    // Set to true to open the right sidebar.
    //
    const [rightSidebarOpen, setRightSidebarOpen] = useState<boolean>(false);

    //
    // Set to true to open the configuration dialog.
    //
    const [configurationOpen, setConfigurationOpen] = useState<boolean>(false);

    //
    // Set to true to open the "open database" modal.
    //
    const [openDatabaseModalOpen, setOpenDatabaseModalOpen] = useState<boolean>(false);

    //
    // Set to true to open the "create database" modal.
    //
    const [createDatabaseModalOpen, setCreateDatabaseModalOpen] = useState<boolean>(false);

    const { openSearch } = useSearch();

    const platform = usePlatform();
    const config = useConfig();

    const theme = useTheme();

    const { mode, setMode } = useColorScheme();

    //
    // Set initial theme mode synchronously on first render only.
    //
    useLayoutEffect(() => {
        setMode(initialTheme);
        // eslint-disable-next-line react-hooks/exhaustive-deps
    }, []); // Only run once on mount - don't reset when mode changes

    const { addToast } = useToast();
    const navigate = useNavigate();
    const { status: importStatus, importItems } = useImport();

    //
    // Show a completion toast when an import finishes, with a "View Import" action button.
    //
    useEffect(() => {
        if (importStatus === 'completed') {
            const successCount = importItems.filter(item => item.status === 'success').length;
            addToast({
                message: `Import complete: ${successCount} asset${successCount !== 1 ? 's' : ''} added`,
                color: 'success',
                duration: 0,
                action: {
                    label: 'View Import',
                    onClick: () => navigate('/import'),
                },
            });
        }
    // eslint-disable-next-line react-hooks/exhaustive-deps
    }, [importStatus]);

    //
    // Subscribe to show-notification events from the main process and display toasts.
    //
    useEffect(() => {
        const unsubscribe = platform.onShowNotification((data) => {
            addToast({
                message: data.message,
                color: data.color,
                duration: data.duration,
                action: data.folderPath
                    ? { label: 'Open Folder', onClick: () => platform.openFolder(data.folderPath!) }
                    : undefined,
            });
        });
        return unsubscribe;
    }, [platform, addToast]);

    //
    // Listen for theme changes from menu.
    //
    useEffect(() => {
        // Subscribe to theme changes
        const unsubscribe = platform.onThemeChanged((theme) => {
            setMode(theme);
        });

        return unsubscribe;
    }, [platform, setMode]);

    //
    // Listen for open-configuration menu action from the main process.
    //
    useEffect(() => {
        const unsubscribe = platform.onMenuAction('open-configuration', () => {
            setConfigurationOpen(true);
        });

        return unsubscribe;
    }, [platform]);

    //
    // Listen for new-database menu action from the main process.
    //
    useEffect(() => {
        const unsubscribe = platform.onMenuAction('new-database', () => {
            setCreateDatabaseModalOpen(true);
        });

        return unsubscribe;
    }, [platform]);

    //
    // Listen for open-database menu action from the main process.
    //
    useEffect(() => {
        const unsubscribe = platform.onMenuAction('open-database', () => {
            setOpenDatabaseModalOpen(true);
        });

        return unsubscribe;
    }, [platform]);

    //
    // Listen for navigate events from the main process.
    //
    useEffect(() => {
        return platform.onNavigate((page) => {
            navigate(page);
        });
    }, [platform, navigate]);

    //
    // Adds mobile or desktop class to body based on isMobile prop.
    //
    useEffect(() => {
        document.body.classList.remove('mobile', 'desktop');
        document.body.classList.add(isMobile ? 'mobile' : 'desktop');
        
        // Cleanup: remove class on unmount
        return () => {
            document.body.classList.remove('mobile', 'desktop');
        };
    }, [isMobile]);

    //
    // Auto-open last database when no database is loaded (only once on initial mount).
    //
    useEffect(() => {
        async function autoOpenLastDatabase() {
            // Only auto-open if no database is currently loaded
            if (databasePath) {
                return;
            }

            try {
                const lastDatabase = await config.get<string>('lastDatabase');
                if (lastDatabase) {
                    await openDatabase(lastDatabase);
                }
            }
            catch (error) {
                log.exception("Error auto-opening last database:", error as Error);
            }
        }

        autoOpenLastDatabase();
        // eslint-disable-next-line react-hooks/exhaustive-deps
    }, []); // Only run once on mount

    return (
        <>
            <Navbar
                sidebarOpen={sidebarOpen}
                setSidebarOpen={setSidebarOpen}
                setRightSidebarOpen={setRightSidebarOpen}
                onOpenConfiguration={() => setConfigurationOpen(true)}
            />

            <Drawer
                open={sidebarOpen}
                onClose={() => setSidebarOpen(false)}
                >
                <LeftSidebar
                    sidebarOpen={sidebarOpen}
                    setSidebarOpen={setSidebarOpen}
                    onOpenConfiguration={() => setConfigurationOpen(true)}
                    onNewDatabase={() => setCreateDatabaseModalOpen(true)}
                    onOpenDatabase={() => setOpenDatabaseModalOpen(true)}
                    />
            </Drawer>

            <Drawer
                anchor="right"
                open={rightSidebarOpen}
                onClose={() => setRightSidebarOpen(false)}
                >
                <RightSidebar
                    sidebarOpen={rightSidebarOpen}
                    setSidebarOpen={setRightSidebarOpen}
                    />
            </Drawer>

            <div
                id="main"
                className={`select-none ` + classNames({ "search": openSearch })}
                style={{
                    backgroundColor: theme.palette.background.body,
                    color: theme.palette.text.primary,
                }}
                >
                <div id="content" >
                    <Routes>
                        {/* TODO: Move to a DatabaseView component. */}
                        <Route
                            path="/gallery/:assetId?"
                            element={
                                <GalleryPage
                                    />
                            }
                            />

                        <Route
                            path="/map/:assetId?"
                            element={<MapPage />}
                            />

                        <Route
                            path="/about"
                            element={<AboutPage />}
                            />

                        <Route
                            path="/import"
                            element={<ImportPage />}
                            />

                        <Route
                            path="/databases"
                            element={<DatabasesPage />}
                            />

                        <Route
                            path="/secrets"
                            element={<SecretsPage />}
                            />

                        <Route
                            path="/"
                            element={
                                <Navigate
                                    replace
                                    to="/gallery"
                                    />
                            }
                            />
                            
                    </Routes>
                </div>
            </div>


            <ConfigurationDialog
                open={configurationOpen}
                onClose={() => setConfigurationOpen(false)}
                />

            <OpenDatabaseModal
                open={openDatabaseModalOpen}
                onClose={() => setOpenDatabaseModalOpen(false)}
                />

            <CreateDatabaseModal
                open={createDatabaseModalOpen}
                onClose={() => setCreateDatabaseModalOpen(false)}
                />

            {isWorking
                && <FullscreenSpinner />
            }

            <Fps />

            <ToastContainer />
        </>
    );
}

//
// Wrapped/exported version of Main that ties in the MUI theme.
//
export function Main({ isMobile, initialTheme }: IMainProps) {
    return (
        <CssVarsProvider defaultMode={initialTheme}>
            <__Main isMobile={isMobile} initialTheme={initialTheme} />
        </CssVarsProvider>
    );
}
