import React, { useEffect, useState } from "react";
import { Route, Routes, Navigate } from "react-router-dom";
import { GalleryPage } from "./pages/gallery/gallery";
import classNames from "classnames";
import { usePlatform } from "./context/platform-context";
import { useAssetDatabase } from "./context/asset-database-source";
import { useSearch } from "./context/search-context";
import { FullscreenSpinner } from "./components/full-screen-spinnner";
import { CssVarsProvider, useColorScheme } from "@mui/joy/styles/CssVarsProvider";
import { ModeToggle } from "./components/mode-toggle";
import { useTheme } from "@mui/joy/styles/ThemeProvider";
import Drawer from "@mui/joy/Drawer/Drawer";
import { Sidebar } from "./components/sidebar";
import { Navbar } from "./components/navbar";
import { Fps } from "./components/fps";
import { AboutPage } from "./pages/about";

const isProduction = (import.meta.env.MODE === "production");

export interface IMainProps {
    //
    // Set to true if running on mobile device to enable mobile-specific styles.
    //
    isMobile?: boolean;
}

//
// The main page of the Photosphere app.
//
function __Main({ isMobile = false }: IMainProps) {

    const { 
        isWorking,
        databasePath,
        openDatabase,
    } = useAssetDatabase();

    //
    // Set to true to open the sidebar.
    //
    const [sidebarOpen, setSidebarOpen] = useState<boolean>(false);

    const { openSearch } = useSearch();

    const platform = usePlatform();

    const theme = useTheme();

    const { mode, setMode } = useColorScheme();

    //
    // Automatically choose system mode on mount.
    //
    useEffect(() => {
        setMode("system");
    }, [setMode]);

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
                const recentDatabases = await platform.getRecentDatabases();
                // The first database in the list is the most recently opened (lastDatabase)
                if (recentDatabases.length > 0) {
                    const lastDatabase = recentDatabases[0];
                    // Call openDatabase to properly update the lastDatabase in config
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
            />

            <Drawer 
                open={sidebarOpen} 
                onClose={() => setSidebarOpen(false)}
                >
                <Sidebar
                    sidebarOpen={sidebarOpen}
                    setSidebarOpen={setSidebarOpen}
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
                            path="/cloud/:assetId?" 
                            element={
                                <GalleryPage
                                    />
                            }
                            />

                        {/* Placeholder route to avoid the warning before the redirect. */}
                        <Route
                            path="/cloud"
                            element={<div/>}
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
                                    to="/cloud"
                                    />
                            }
                            />
                            
                    </Routes>
                </div>
            </div>


            {isWorking
                && <FullscreenSpinner />
            }

            <Fps />
        </>
    );
}

//
// Wrapped/exported version of Main that ties in the MUI theme.
//
export function Main({ isMobile }: IMainProps) {
    return (
        <CssVarsProvider>
            {!isProduction &&
                <ModeToggle />
            }
            <__Main isMobile={isMobile} />
        </CssVarsProvider>
    );
}
