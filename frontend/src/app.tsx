import React, { useState } from "react";
import { BrowserRouter, Route, Routes, NavLink, Navigate } from "react-router-dom";
import { AssetView } from "./components/asset-view";
import { ISelectedGalleryItem } from "./lib/gallery-item";
import { GalleryPage } from "./pages/gallery";
import { UploadPage } from "./pages/upload";
import { useGallery } from "./context/gallery-context";

export function App() {

    //
    // Interface to the gallery.
    //
    const { 
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

    function notImplemented(event: any) {
        alert("This is a not implemented yet.");

        event.preventDefault();
        event.stopPropagation();
    }

    return (
        <BrowserRouter>
            <div id="navbar">
                <div className="flex flex-row items-center pl-6 pt-3 pb-2">
                    <button
                        onClick={() => setSidebarOpen(!sidebarOpen)}
                        >
                        <i className="fa-solid fa-bars"></i>
                    </button>

                    <h1 className="ml-10">Photosphere</h1>

                    <button
                        className="ml-16 mr-3"
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

                <div className={"search flex flex-row items-stretch " + (openSearch ? "open": "")}>
                    <button
                        className="w-10 text-xl"
                        onClick={event => {
                            setOpenSearch(false);
                        }}
                        >
                        <i className="fa-solid fa-close"></i>
                    </button>
                    <input 
                        className="search-input flex-grow"
                        placeholder="Type your search and press enter"
                        />
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
                    onClick={event => {
                        setOpenSearch(true);
                    }}
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
                                    onItemClick={setSelectedItem}
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
                <AssetView
                    open={!!selectedItem}
                    asset={selectedItem.item}
                    onClose={() => {
                        setSelectedItem(undefined);
                    }}
                    onPrev={() => {
                        setSelectedItem(getPrev(selectedItem));
                    }}
                    onNext={() => {
                        setSelectedItem(getNext(selectedItem));
                    }}
                    />
            }

        </BrowserRouter>
    );
}