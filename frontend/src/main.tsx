import React, { useState } from "react";
import { BrowserRouter, Route, Routes, NavLink, Navigate, useNavigate } from "react-router-dom";
import { AssetView } from "./components/asset-view";
import { Spinner } from "./components/spinner";
import { ISelectedGalleryItem } from "./lib/gallery-item";
import { GalleryPage } from "./pages/gallery";
import { UploadPage } from "./pages/upload";
import { useGallery } from "./context/gallery-context";
import { GalleryItemContextProvider } from "./context/gallery-item-context";

//
// The main page of the Photosphere app.
//
export function Main() {

    //
    // Interface to React Router navigation.
    //
	const navigate = useNavigate();
	
    //
    // Interface to the gallery.
    //
    const { 
        searchText,
        search,
        clearSearch,
        getNext, 
        getPrev, 
        selectedItem, 
        setSelectedItem 
        } = useGallery();

    //
    // Set to true to open the sidebar.
    //
    const [sidebarOpen, setSidebarOpen] = useState<boolean>(false);

    // 
    // Set to true to open the search input.
    //
    const [openSearch, setOpenSearch] = useState<boolean>(false);
    
    //
    // Opens the asset view modal.
    //
    const [openAssetView, setOpenAssetView] = useState<boolean>(false);

    //
    // The search currently being typed by the user.
    //
    const [ searchInput, setSearchInput ] = React.useState<string>("");

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

                        <h1 className="ml-4">Photosphere</h1>

                        <button
                            className="ml-8 mr-3"
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
                            className="mr-3"
                            to="/cloud"
                            >
                            <div className="flex flex-row items-center">
                                <i className="w-5 text-center fa-solid fa-cloud"></i>
                                <div className="hidden sm:block ml-2">Cloud</div>
                            </div>
                        </NavLink>

                        <NavLink
                            className="mr-3"
                            to="/upload"
                        >
                            <div className="flex flex-row items-center">
                                <i className="w-5 text-center fa-solid fa-upload"></i>
                                <div className="hidden sm:block ml-2">Upload</div>
                            </div>
                        </NavLink>

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

            <div id="sidebar" className={sidebarOpen ? "open" : ""} >
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

                <NavLink to="/upload">
                    <div className="flex flex-row items-center pl-1 mt-2">
                        <i className="w-12 text-center fa-solid fa-upload"></i>
                        <div className="">Upload</div>
                    </div>
                </NavLink>

                <button
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
                </button>
            </div>

            <div id="main">
                <div id="content" className={sidebarOpen ? "open" : ""} >
                    <Routes>
                        <Route 
                            path="/cloud" 
                            element={
                                <GalleryPage
                                    key={searchText} // Forces the gallery to update when the search changes.
                                    onItemClick={item => {
                                        setOpenAssetView(true);
                                        setSelectedItem(item);
                                    }}
                                    />
                            }
                            />

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
                    </Routes>
                </div>
            </div>

            {selectedItem &&
                <GalleryItemContextProvider 
                    asset={selectedItem.item}
                    assetIndex={selectedItem.index}
                    key={selectedItem.item._id}
                    >
		            <AssetView
	                    key={selectedItem.item._id}
		                open={openAssetView}
		                onClose={() => {
	                        setOpenAssetView(false);
		                }}
		                onPrev={() => {
	                        setSelectedItem(getPrev(selectedItem));
		                }}
		                onNext={() => {
	                        setSelectedItem(getNext(selectedItem));
		                }}
		                />
                </GalleryItemContextProvider>
            }
        </>
    );
}