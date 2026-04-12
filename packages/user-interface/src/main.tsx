import React, { useEffect, useLayoutEffect, useState } from "react";
import { Route, Routes, Navigate } from "react-router-dom";
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
import { ToastContextProvider, useToast } from "./context/toast-context";
import { ToastContainer } from "./components/toast-container";

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
    // Listen for open-configuration events from the main process (e.g. menu item).
    //
    useEffect(() => {
        const unsubscribe = platform.onOpenConfiguration(() => {
            setConfigurationOpen(true);
        });

        return unsubscribe;
    }, [platform]);

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
                console.error("Error auto-opening last database:", error);
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
            <ToastContextProvider>
                <__Main isMobile={isMobile} initialTheme={initialTheme} />
            </ToastContextProvider>
        </CssVarsProvider>
    );
}
