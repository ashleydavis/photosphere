import React, { useEffect, useState } from "react";
import { Route, Routes, Navigate } from "react-router-dom";
import { GalleryPage } from "./pages/gallery/gallery";
import { useGallery } from "./context/gallery-context";
import classNames from "classnames";
import { useApp } from "./context/app-context";
import { usePlatform } from "./context/platform-context";
import { useAssetDatabase } from "./context/asset-database-source";
import { useSearch } from "./context/search-context";
import { FullscreenSpinner } from "./components/full-screen-spinnner";
import { DeleteConfirmationDialog } from "./components/delete-confirmation-dialog";
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
        sortedItems,
        selectedItems,
        clearMultiSelection,
        searchText,
    } = useGallery();

    const { 
        isLoading,
        isWorking,
        databasePath,
        moveToDatabase, 
        deleteAssets,
        selectAndOpenDatabase,
        openDatabase,
    } = useAssetDatabase();

    //
    // Set to true to open the sidebar.
    //
    const [sidebarOpen, setSidebarOpen] = useState<boolean>(false);

    const { openSearch, setOpenSearch, searchInput, setSearchInput, onCommitSearch, onCloseSearch } = useSearch();

    //
    // Opens the delete confirmation dialog.
    //
    const [deleteConfirmationOpen, setDeleteConfirmationOpen] = useState<boolean>(false);

    //
    // Track if the smoke test button was clicked.
    //
    const [buttonClicked, setButtonClicked] = useState<boolean>(false);

    const { dbs } = useApp();
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

    useEffect(() => {
        if (searchText.length > 0 && !openSearch) {
            setSearchInput(searchText);
            setOpenSearch(true);
        }
    }, [searchText, openSearch, setSearchInput, setOpenSearch]);

    //
    // Moves selected items to the specified database.
    //
    async function onMoveSelectedToDatabase(databaseid: string) {
        await moveToDatabase(Array.from(selectedItems), databaseid);
    }

    // Show initial message if no database is loaded
    if (!databasePath) {
        return (
            <>
                <div 
                    id="navbar" 
                    className="select-none"
                    style={{
                        backgroundColor: theme.palette.background.body,
                        color: theme.palette.text.primary,
                    }}
                >
                    <div className="flex flex-row items-center pl-4 pt-3 pb-2">
                        <h1 className="ml-3 sm:ml-4">Photosphere</h1>
                    </div>
                </div>
                <div
                    id="main"
                    className="select-none flex items-center justify-center"
                    style={{
                        backgroundColor: theme.palette.background.body,
                        color: theme.palette.text.primary,
                        height: "calc(100vh - 60px)",
                    }}
                >
                    <div className="text-center">
                        {/* Smoke test button - visible for testing */}
                        <div style={{ padding: "20px", textAlign: "center" }}>
                            <button
                                onClick={() => setButtonClicked(true)}
                                style={{
                                    padding: "10px 20px",
                                    fontSize: "16px",
                                    cursor: "pointer",
                                }}
                            >
                                Click me
                            </button>
                            {buttonClicked && (
                                <div style={{ marginTop: "10px", fontSize: "16px" }}>
                                    Button was pressed
                                </div>
                            )}
                        </div>
                        <button
                            onClick={async () => {
                                await selectAndOpenDatabase();
                            }}
                            className="px-6 py-3 bg-blue-500 text-white rounded-lg hover:bg-blue-600 transition-colors"
                            style={{
                                backgroundColor: theme.palette.primary[500] || "#3b82f6",
                            }}
                        >
                            Click here to open a database
                        </button>
                    </div>
                </div>
            </>
        );
    }
   
    return (
        <>
            <Navbar
                sidebarOpen={sidebarOpen}
                setSidebarOpen={setSidebarOpen}
                sortedItemsCount={sortedItems().length}
                selectedItemsCount={selectedItems.size}
                clearMultiSelection={clearMultiSelection}
                isLoading={isLoading}
                databasePath={databasePath}
                dbs={dbs}
                onMoveSelectedToDatabase={onMoveSelectedToDatabase}
                setDeleteConfirmationOpen={setDeleteConfirmationOpen}
            />

            <Drawer 
                open={sidebarOpen} 
                onClose={() => setSidebarOpen(false)}
                >
                <Sidebar
                    sidebarOpen={sidebarOpen}
                    setSidebarOpen={setSidebarOpen}
                    openDatabase={openDatabase}
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
                    {/* Smoke test button - visible for testing */}
                    <div style={{ padding: "20px", textAlign: "center" }}>
                        <button
                            onClick={() => setButtonClicked(true)}
                            style={{
                                padding: "10px 20px",
                                fontSize: "16px",
                                cursor: "pointer",
                            }}
                        >
                            Click me
                        </button>
                        {buttonClicked && (
                            <div style={{ marginTop: "10px", fontSize: "16px" }}>
                                Button was pressed
                            </div>
                        )}
                    </div>
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

            <DeleteConfirmationDialog
                open={deleteConfirmationOpen}
                numItems={selectedItems.size}
                onCancel={() => setDeleteConfirmationOpen(false)}
                onDelete={async () => {
                    await deleteAssets(Array.from(selectedItems.values()));
                    clearMultiSelection();
                    setDeleteConfirmationOpen(false);
                }}
                />

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