import React, { useState } from "react";
import { Route, Routes, NavLink, Navigate, useNavigate } from "react-router-dom";
import { Spinner } from "./components/spinner";
import { GalleryPage } from "./pages/gallery/gallery";
import { UploadPage } from "./pages/upload";
import { useUpload } from "./context/upload-context";
import { enableAuth, isProduction, useAuth } from "./context/auth-context";
import { useGallery } from "./context/gallery-context";
import classNames from "classnames";
import { useApp } from "./context/app-context";
import { deleteDatabase } from "./lib/database/indexeddb/indexeddb";
import { useIndexeddb } from "./context/indexeddb-context";
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
export function Main({ computerPage }: IMainProps) {

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
        items,
        searchText,
        search,
        clearSearch,
    } = useGallery();

    const {
        setId,
        setSetId,
    } = useApp();

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
    const [ searchInput, setSearchInput ] = React.useState<string>("");

    const { user } = useApp();

    function notImplemented(event: any) {
        alert("This is a not implemented yet.");

        event.preventDefault();
        event.stopPropagation();
    }

    //
    // Opens the search input.
    //
    async function onOpenSearch() {
    	setOpenSearch(true);
        navigate("/cloud");
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
    }

    async function onLogOut() {
        await logout();

        await deleteDatabase();
    }

    return (
        <>
            <div id="navbar" className={(openSearch ? "search": "")} >
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
                            className="mr-2 text-xs sm:text-sm"
                            >
                            {items.length} photos
                        </div>

                        {!isAuthenticated && (
                            <div className="ml-1 mr-2 sm:mr-4">
                                <button
                                    onClick={login}
                                    >
                                    <i className="w-5 fa-solid fa-right-to-bracket"></i>
                                    <span className="hidden sm:inline ml-2">Log in</span>
                                </button>
                            </div> 
                        )}

                        {isAuthenticated && (
                            <div className="ml-1 mr-2 sm:mr-4">
                                <button
                                    onClick={onLogOut}
                                    >
                                    <i className="w-5 fa-solid fa-right-from-bracket"></i>
                                    <span className="hidden sm:inline ml-1">Log out</span>
                                </button>
                            </div> 
                        )}
                    </div>

                    {openSearch
                        && <div className="flex flex-row items-center pt-3 pb-3 pl-4 pr-1">
                            <div>
                                <i className="fa-solid fa-search"></i>
                            </div>
                            <input
                                autoFocus 
                                className="search-input flex-grow ml-4 outline-none"
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

            <div id="sidebar" className={classNames("flex flex-col", { "open": sidebarOpen})} >
                <div className="flex flex-row items-center mt-4 mb-8">
                    <h1 className="text-xl">
                        Photosphere
                    </h1>
                    <div className="flex-grow" />
                    <button
                        className="mr-3 text-xl"
                        onClick={() => setSidebarOpen(!sidebarOpen)}
                    >
                        <i className="fa-solid fa-arrow-left"></i>
                    </button>
                </div>

                <button
                    onClick={onOpenSearch}
                    >
                    <div className="flex flex-row items-center pl-1">
                        <i className="w-12 text-center fa-solid fa-search"></i>
                        <div className="">Search</div>
                    </div>
                </button>

                <NavLink to="/cloud">
                    <div className="flex flex-row items-center pl-1 mt-8">
                        <i className="w-12 text-center fa-solid fa-cloud"></i>
                        <div className="">Cloud</div>
                    </div>
                </NavLink>

                {computerPage 
                    && <NavLink to="/computer">
                        <div className="flex flex-row items-center pl-1 mt-8">
                            <i className="w-12 text-center fa-solid fa-computer"></i>
                            <div className="">Computer</div>
                        </div>
                    </NavLink>
                }

                <NavLink to="/upload">
                    <div className="flex flex-row items-center pl-1 mt-2">
                        <i className="w-12 text-center fa-solid fa-upload"></i>
                        <div className="">Upload</div>
                    </div>
                </NavLink>

                {/* <button
                    className="flex flex-row items-center pl-1 mt-8 cursor-pointer"
                    onClick={event => notImplemented(event)}
                    >
                    <i className="w-12 text-center fa-regular fa-star"></i>
                    <div className="">Favorites</div>
                </button>

                <button
                    className="flex flex-row items-center pl-1 mt-2 cursor-pointer"
                    onClick={event => notImplemented(event)}
                    >
                    <i className="w-12 text-center fa-regular fa-trash-can"></i>
                    <div className="">Trash</div>
                </button> */}

                <div className="flex flex-col pl-1 mt-4 mb-8">
                    <h2 className="text-lg">
                        Sets
                    </h2>

                    {user?.sets.access.map(set => {
                        return (
                            <button
                                key={set}
                                className="flex flex-row items-center cursor-pointer"
                                onClick={() => setSetId(set)}
                                >
                                <div className="flex flex-row items-center pl-1 mt-8">
                                    <i className={classNames("w-12 text-center fa-solid fa-folder", {
                                        "fa-folder": setId !== set,
                                        "fa-folder-open": setId === set,
                                    })}></i>
                                    <div className="">{set}</div>
                                </div>
                            </button>
                        );                    
                    })}
                </div>

                <div className="flex-grow" />

                {!enableAuth && (
                    <button 
                        className="flex flex-row items-center p-2 m-2 cursor-pointer"
                        onClick={deleteDatabase}
                        >
                        Delete local database
                    </button>
                )}
            </div>

            <div id="main" className={classNames({ "search": openSearch})} >
                <div id="content" >
                    <Routes>
                        <Route 
                            path="/cloud" 
                            element={
                                <GalleryPage
                                    key={searchText} // Forces the gallery to update when the search changes.
                                    />
                            }
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