import React, { useEffect, useState } from "react";
import { Route, Routes, NavLink, Navigate, useNavigate, useLocation } from "react-router-dom";
import { Spinner } from "./components/spinner";
import { GalleryPage } from "./pages/gallery/gallery";
import { UploadPage } from "./pages/upload";
import { useUpload } from "./context/upload-context";
import { enableAuth, isProduction, useAuth } from "./context/auth-context";
import { useGallery } from "./context/gallery-context";
import classNames from "classnames";
import { useApp } from "./context/app-context";
import { useIndexeddb } from "./context/indexeddb-context";
import Dropdown from '@mui/joy/Dropdown';
import MenuButton from '@mui/joy/MenuButton';
import IconButton from '@mui/joy/IconButton';
import MoreVert from '@mui/icons-material/MoreVert';
import MenuItem from '@mui/joy/MenuItem';
import Menu from '@mui/joy/Menu';
import ListDivider from '@mui/joy/ListDivider';
import ListSubheader from "@mui/joy/ListSubheader";
import { useAssetDatabase } from "./context/asset-database-source";
import { FullscreenSpinner } from "./components/full-screen-spinnner";
import Delete from "@mui/icons-material/Delete";
import { DeleteConfirmationDialog } from "./components/delete-confirmation-dialog";
import { CssVarsProvider, useColorScheme } from "@mui/joy/styles/CssVarsProvider";
import { ModeToggle } from "./components/mode-toggle";
import { useTheme } from "@mui/joy/styles/ThemeProvider";
import Drawer from "@mui/joy/Drawer/Drawer";
import { Sidebar } from "./components/sidebar";
import Input from "@mui/joy/Input/Input";
const FPSStats = require("react-fps-stats").default;

export interface IMainProps {
    //
    // The "computer page" which is only displayed in the Electron or mobile version.
    //
    computerPage?: JSX.Element;
}

//
// The main page of the Photosphere app.
//
function __Main({ computerPage }: IMainProps) {

    const {
        isLoading,
        isAuthenticated,
        login,
        logout,
    } = useAuth();

    //
    // Interface to React Router navigation.
    //
	const navigate = useNavigate();

    const { 
        isLoading: isGalleryLoading,
        getSearchedItems,
        selectedItemId,
        selectedItems,
        clearMultiSelection,
        searchText,
        search,
        clearSearch,
        onReset,
        onNewItems,
    } = useGallery();

    const { 
        isWorking,
        setId,
        moveToSet, 
        deleteAssets,
    } = useAssetDatabase();

    const {
        deleteDatabase
    } = useIndexeddb();

    //
    // Interface to the upload context.
    //
    const { numScans, isUploading } = useUpload();

    //
    // Set to true to open the sidebar.
    //
    const [sidebarOpen, setSidebarOpen] = useState<boolean>(false);

    // 
    // Set to true to open the search input.
    //
    const [openSearch, setOpenSearch] = useState<boolean>(false);
    
    //
    // The search currently being typed by the user.
    //
    const [ searchInput, setSearchInput ] = useState<string>("");

    //
    // Opens the delete confirmation dialog.
    //
    const [deleteConfirmationOpen, setDeleteConfirmationOpen] = useState<boolean>(false);

    //
    // Number of assets loaded.
    //
    const [numLoaded, setNumLoaded] = useState<number>(0);

    const { user } = useApp();

    const location = useLocation();

    const theme = useTheme();

    const { mode, setMode } = useColorScheme();

    setMode("system"); // Automatically choose system mode.

    //
    // Resets the gallery layout.
    //
    useEffect(() => {
        const subscription = onReset.subscribe(() => {
            setNumLoaded(getSearchedItems().length);
        });
        return () => {
            subscription.unsubscribe();            
        };
    }, []);

    //
    // New items added to the gallery.
    //
    useEffect(() => {
        const subscription = onNewItems.subscribe(() => {
            setNumLoaded(getSearchedItems().length);
        });
        return () => {
            subscription.unsubscribe();            
        };
    }, []);

    useEffect(() => {
        if (location.pathname === "/cloud" && user) {
            //
            // If the user is logged in, navigate to their default set.
            //
            navigateToDefaultSet();
        }
    }, [user, location]);

    useEffect(() => {
        if (setId) {
            if (selectedItemId) {
                navigate(`/cloud/${setId}/${selectedItemId}`);
            }
            else {
                navigate(`/cloud/${setId}`);
            }
        }
    }, [setId, selectedItemId]);

    useEffect(() => {
        if (searchText.length > 0 && !openSearch) {
            setSearchInput(searchText);
            setOpenSearch(true);
        }
    }, [searchText]);


    //
    // Navigate to the specified set.
    //
    function navigateToSet(setId: string) {
        navigate(`/cloud/${setId}`);
    }

    //
    // Navigate to the users default set.
    //
    function navigateToDefaultSet() {
        console.log(`Navigating to default set.`)

        if (!user) {
            throw new Error(`No user set.`);
        }

        navigateToSet(user.defaultSet);
    }

    //
    // Opens the search input.
    //
    function onOpenSearch() {
    	setOpenSearch(true);
        navigateToDefaultSet();
    }

    //
    // Commits the search the user has typed in.
    // 
    async function onCommitSearch() {
        await search(searchInput);
    }

    //
    // Cancels/closes the search.
    //
    async function onCloseSearch() {
        await clearSearch();
        setSearchInput("");
        setOpenSearch(false);
    }

    //
    // Logs the user out.
    //
    async function onLogOut() {
        await logout();

        await deleteDatabase();
    }

    //
    // Moves selected items to the specified set.
    //
    async function onMoveSelectedToSet(setId: string) {
        await moveToSet(Array.from(selectedItems), setId);
    }

    if (enableAuth) {       
        if (isLoading) {
            return (
                <div className="flex items-center justify-center absolute bg-white bg-opacity-50 inset-0">
                    <Spinner show={true} />
                </div>
            );
        }
    
        if (!isAuthenticated) {
            login()
                .catch(err => {
                    console.error(`Error on login:`);
                    console.error(err);
                });
            return (
                <div className="flex items-center justify-center absolute bg-white bg-opacity-50 inset-0">
                    <Spinner show={true} />
                </div>
            );
        }

        if (location.pathname === "/cloud") {
            return (
                <div className="flex items-center justify-center absolute bg-white bg-opacity-50 inset-0">
                    <Spinner show={true} />
                </div>
            );
       }
    }
   
    return (
        <>
            <div 
                id="navbar" 
                className={"select-none " + (openSearch ? "search": "")} 
                style={{
                    backgroundColor: theme.palette.background.body,
                    color: theme.palette.text.primary,
                }}
                >
                <div className="flex flex-col">
                    <div className="flex flex-row items-center pl-4 pt-3 pb-2">
                        <button
                            onClick={() => setSidebarOpen(!sidebarOpen)}
                            >
                            <i className="fa-solid fa-bars"></i>
                        </button>

                        <h1 className="ml-3 sm:ml-4">Photosphere</h1>

                        <button
                            className="ml-4 mr-1 sm:ml-8 sm:mr-3"
                        	onClick={event => {
                            	setOpenSearch(true);
                            }}
                            >
                            <div className="flex flex-row items-center">
                                <i className="w-5 text-center fa-solid fa-search"></i>
                                <div className="hidden sm:block ml-2">Search</div>
                            </div>
                        </button>

                        <NavLink
                            className="mr-1 sm:mr-3"
                            to="/cloud"
                            >
                            <div className="flex flex-row items-center">
                                <i className="w-5 text-center fa-solid fa-cloud"></i>
                                <div className="hidden sm:block ml-2">Cloud</div>
                            </div>
                        </NavLink>

                        {computerPage && 
                            <NavLink
                                className="mr-1 sm:mr-3"
                                to="/computer"
                                >
                                <div className="flex flex-row items-center">
                                    <i className="w-5 text-center fa-solid fa-computer"></i>
                                    <div className="hidden sm:block ml-2">Computer</div>
                                </div>
                            </NavLink>
                        }

                        <NavLink
                            className="mr-1 sm:mr-3"
                            to="/upload"
                            >
                            <div className="flex flex-row items-center">
                                <i className="w-5 text-center fa-solid fa-upload"></i>
                                <div className="hidden sm:block ml-2">Upload</div>
                            </div>
                        </NavLink>

                        <div className="ml-auto"></div>

                        {(isGalleryLoading)
                            && <div className="flex flex-row items-center ml-1 mr-2">
                                <span className="text-sm hidden sm:block mr-1">Loading</span>
                                <div className="mx-1 sm:mx-2">
                                    <Spinner show={true} />
                                </div>
                            </div>
                        }

                        {(isUploading || numScans > 0)
                            && <div className="flex flex-row items-center ml-1 mr-2">
                                <span className="text-sm hidden sm:block mr-1">Uploading</span>
                                <div className="mx-1 sm:mx-2">
                                    <Spinner show={true} />
                                </div>
                            </div>
                        }

                        <div
                            className="flex flex-row items-center mr-2 text-xs sm:text-sm"
                            >
                            {selectedItems.size > 0 
                                && <div className="flex flex-row items-center">
                                    <button
                                        className="w-6 text-sm"
                                        onClick={clearMultiSelection}
                                        >
                                        <i className="fa-solid fa-close"></i>
                                    </button>                                    
                                    {selectedItems.size} selected
                                </div>
                                || <div>{getSearchedItems().length} photos</div>
                            }
                            
                        </div>

                        <Dropdown>
                            <MenuButton
                                sx={{
                                    mr: 1,
                                }}                            
                                slots={{ root: IconButton }}
                                slotProps={{ root: { variant: 'soft', color: 'neutral' } }}
                                >
                                <MoreVert />
                            </MenuButton>
                            <Menu placement="bottom-end">
                                {selectedItems.size > 0
                                    && <>
                                        <ListSubheader>MOVE TO</ListSubheader>
                                        {user?.sets.map(set => {
                                            if (set.id === setId) {
                                                return null; // Don't show the current set.
                                            }
                                            return (
                                                <MenuItem 
                                                    key={set.id}
                                                    onClick={() => onMoveSelectedToSet(set.id)}
                                                    >
                                                    {set.name}                                        
                                                </MenuItem>
                                            );
                                        })}
                                        <ListDivider />
                                        <MenuItem
                                            color="danger"
                                            onClick={() => setDeleteConfirmationOpen(true)}
                                            >
                                            <Delete />
                                            Delete {selectedItems.size} assets
                                        </MenuItem>                                        
                                        <ListDivider />
                                    </>
                                }
                                <MenuItem
                                    onClick={onLogOut}
                                    >
                                    <i className="fa-solid fa-right-from-bracket"></i>
                                    <span className="ml-1">Log out</span>
                                </MenuItem>
                            </Menu>
                        </Dropdown>
                    </div>

                    {openSearch
                        && <div className="flex flex-row items-center pl-4 pr-1">
                            <div>
                                <i className="fa-solid fa-search"></i>
                            </div>
                            <Input
                                size="sm"
                                autoFocus 
                                className="flex-grow ml-4 outline-none"
                                placeholder="Type your search and press enter"
                                value={searchInput} 
                                onChange={event => {
                                    setSearchInput(event.target.value);
                                }}
                                onKeyDown={async event => {
                                    if (event.key === "Enter") {
                                        //
                                        // Commits the search.
                                        //
                                        await onCommitSearch();
                                    }
                                    else if (event.key === "Escape") {
                                        //
                                        // Cancels the search.
                                        //
                                        await onCloseSearch();
                                    }
                                }}
                                />
                            <button
                                className="w-10 text-xl"
                            	onClick={onCloseSearch}
                                >
                                <i className="fa-solid fa-close"></i>
                            </button>
                        </div>
                    }                    
                </div>
                
            </div>

            <Drawer 
                open={sidebarOpen} 
                onClose={() => setSidebarOpen(false)}
                >
                <Sidebar
                    sidebarOpen={sidebarOpen}
                    setSidebarOpen={setSidebarOpen}
                    navigateToSet={navigateToSet}
                    onOpenSearch={onOpenSearch}
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
                        <Route 
                            path="/cloud/:setId/:assetId?" 
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


                        {computerPage 
                            && <Route
                                path="/computer"
                                element={computerPage}
                                />
                        }

                        <Route 
                            path="/upload" 
                            element={<UploadPage />} 
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

                        <Route
                            path="/on_login"
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

            {!isProduction 
                && <FPSStats 
                    top="auto"
                    left="auto"
                    right={30}
                    bottom={10}
                    />
            }
        </>
    );
}

//
// Wrapped/exported version of Main that ties in the MUI theme.
//
export function Main({ computerPage }: IMainProps) {
    return (
        <CssVarsProvider>
            {!isProduction &&
                <ModeToggle />
            }
            <__Main computerPage={computerPage} />
        </CssVarsProvider>
    );
}