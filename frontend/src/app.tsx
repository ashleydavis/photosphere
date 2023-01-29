import React, { useState } from "react";
import { BrowserRouter, Route, Routes, NavLink, Navigate } from "react-router-dom";
import { IGalleryItem } from "./lib/gallery-item";
import { GalleryPage } from "./pages/gallery";
import { UploadPage } from "./pages/upload";
import { useApi } from "./context/api-context";

export function App() {

    //
    // Interface to the API.
    //
    const api = useApi();

    //
    // Set to true to open the sidebar.
    //
    const [sidebarOpen, setSidebarOpen] = useState<boolean>(false);

    // 
    // Set to true to open the search input.
    //
    const [openSearch, setOpenSearch] = useState<boolean>(false);
    
    // 
    // Set to true to open asset info.
    //
    const [openInfo, setOpenInfo] = useState<boolean>(false);
    
    //
    // The currently selected gallery item or undefined when no item is selected.
    //
    const [selectedItem, setSelectedItem] = useState<IGalleryItem | undefined>(undefined);

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
                        className="ml-auto mr-3"
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

            <div className={"photo flex flex-col " + (selectedItem ? "open" : "")}>
                <div className="photo-header">
                    <div className="flex flex-row items-center pl-3 pt-3 pb-2">
                        <button
                            className="p-1 px-3"
                            onClick={() => {
                                setSelectedItem(undefined);
                                setOpenInfo(false);
                            }}
                            >
                            <i className="fa-solid fa-close"></i>
                        </button>

                        <NavLink
                            className="ml-auto mr-4"
                            to="/search"
                            onClick={event => notImplemented(event)}
                            >
                            <div className="flex flex-row items-center">
                                <i className="w-4 text-center fa-solid fa-share-nodes"></i>
                                <div className="hidden sm:block ml-2">Share</div>
                            </div>
                        </NavLink>

                        <NavLink
                            className="mr-4"
                            to="/cloud"
                        >
                            <div className="flex flex-row items-center">
                                <i className="w-4 text-center fa-regular fa-star"></i>
                                <div className="hidden sm:block ml-2">Favorite</div>
                            </div>
                        </NavLink>

                        <NavLink
                            className="mr-4"
                            to="/local"
                            onClick={event => {
                                setOpenInfo(true);
                                event.preventDefault();
                                event.stopPropagation();
                            }}
                        >
                            <div className="flex flex-row items-center">
                                <i className="w-4 text-center fa-solid fa-circle-info"></i>
                                <div className="hidden sm:block ml-2">Info</div>
                            </div>
                        </NavLink>

                        <NavLink
                            className="mr-4"
                            to="/trash"
                            onClick={event => notImplemented(event)}
                        >
                            <div className="flex flex-row items-center">
                                <i className="w-3 text-center fa-regular fa-trash-can"></i>
                                <div className="hidden sm:block ml-2">Trash</div>
                            </div>
                        </NavLink>

                        <NavLink
                            className="mr-3"
                            to="/menu"
                            onClick={event => notImplemented(event)}
                        >
                            <div className="flex flex-row items-center">
                                <i className="w-2 text-center fa-solid fa-ellipsis-vertical"></i>
                                <div className="hidden sm:block ml-2">More</div>
                            </div>
                        </NavLink>
                    </div>
                </div>

                <div className="photo-content flex-grow flex flex-col justify-center">
                    <div className="flex flex-grow portrait:flex-row landscape:flex-row">
                        <div className="flex flex-col justify-center">
                            <button
                                className="p-1 px-3"
                                onClick={event => notImplemented(event)}
                                >
                                <i className="fa-solid fa-arrow-left"></i>
                            </button>
                        </div>
                        <div className="flex-grow flex portrait:flex-col landscape:flex-row justify-center">
                            {selectedItem && 
                                <div>
                                    <img
                                        src={api.makeUrl(selectedItem.thumb)}
                                    />
                                </div>
                            }
                        </div>
                        <div className="flex flex-col justify-center">
                            <button
                                className="p-1 px-3"
                                onClick={event => notImplemented(event)}
                                >
                                <i className="fa-solid fa-arrow-right"></i>
                            </button>
                        </div>
                    </div>
                </div>
            </div>

            <div className={"info overflow-scroll " + (openInfo ? "open" : "")}>
                <div className="info-header">
                    <div className="flex flex-row items-center pl-3 pt-3 pb-2">
                        <button
                            className="p-1 px-3"
                            onClick={() => {
                                setOpenInfo(false);
                            }}
                        >
                            <i className="fa-solid fa-close"></i>
                        </button>

                        <h1 className="text-xl ml-2">Info</h1>
                    </div>
                </div>

                <div className="info-content flex flex-col">

                    <div className="flex flex-col flex-grow ml-5 mr-5 mt-6 mb-6 justify-center">
                        <div className="flex flex-row h-8">
                            <textarea
                                className="flex-grow border-b border-solid border-black border-opacity-20"
                                placeholder="Add a description"
                                spellCheck="false"
                                autoComplete="off"
                            >
                            </textarea>
                        </div>

                        <div className="flex flex-col">
                            <div className="text-lg text-gray-600 flex flex-row portrait:mt-10 landscape:mt-4 pt-2">
                                <div className="w-6 mt-2 flex flex-col items-center">
                                    <i className="text-2xl fa-solid fa-tags"></i>
                                </div>
                                <div className="flex flex-col ml-3">
                                    <div className="flex flex-row">
                                        <span
                                            className="flex flex-wrap justify-between items-center text-sm bg-gray-100 hover:bg-gray-200 border border-gray-200 border-solid rounded pl-1 pr-1 py-0">
                                            Label 1
                                            <button
                                                className="ml-1 p-1 pl-2 pr-1"
                                                onClick={event => notImplemented(event)}
                                                >
                                                <i className="fa-solid fa-close"></i>
                                            </button>
                                        </span>
                                        <span
                                            className="ml-2 flex flex-wrap justify-between items-center text-sm bg-gray-100 hover:bg-gray-200 border border-gray-200 border-solid rounded pl-1 pr-1 py-0">
                                            Label 2
                                            <button
                                                className="ml-2 p-1 pl-2 pr-1"
                                                onClick={event => notImplemented(event)}
                                                >
                                                <i className="fa-solid fa-close"></i>
                                            </button>
                                        </span>

                                        <button
                                            className="ml-2 p-1 pl-3 pr-3"
                                            onClick={event => notImplemented(event)}
                                            >
                                            <i className="fa-solid fa-square-plus"></i>
                                        </button>
                                    </div>
                                </div>
                            </div>

                            <div className="text-base text-gray-600 flex flex-row mt-4 pt-2">
                                <div className="w-6 mt-2 flex flex-col items-center">
                                    <i className="text-2xl fa-solid fa-calendar-day"></i>
                                </div>
                                <div className="flex flex-col ml-3">
                                    <div>
                                        Jan 2
                                    </div>
                                    <div className="text-sm flex flex-row" >
                                        <div>Mon, 5:02 PM</div>
                                        <div className="ml-4">GMT+10:00</div>
                                    </div>
                                </div>
                            </div>

                            <div className="text-base text-gray-600 flex flex-row mt-4 pt-2">
                                <div className="w-6 mt-2 flex flex-col items-center">
                                    <i className="text-2xl fa-solid fa-camera"></i>
                                </div>
                                <div className="flex flex-col ml-3">
                                    <div>
                                        Google Pixel 6
                                    </div>
                                    <div className="text-sm flex flex-row" >
                                        <div>ƒ/1.85</div>
                                        <div className="ml-4">1/177</div>
                                        <div className="ml-4">6.81mm</div>
                                        <div className="ml-4">ISO368</div>
                                    </div>
                                </div>
                            </div>

                            <div className="text-base text-gray-600 flex flex-row mt-4 pt-2">
                                <div className="w-6 mt-2 flex flex-col items-center">
                                    <i className="text-2xl fa-regular fa-image"></i>
                                </div>
                                <div className="flex flex-col ml-3">
                                    <div>
                                        PXL_20230102_070227920.jpg
                                    </div>
                                    <div className="text-sm flex flex-row" >
                                        <div>4.9MP</div>
                                        <div className="ml-4">1920 × 2560</div>
                                    </div>
                                </div>
                            </div>

                            <div className="text-base text-gray-600 flex flex-row mt-4 pt-2">
                                <div className="w-6 mt-0 flex flex-col items-center">
                                    <i className="text-2xl fa-solid fa-upload"></i>
                                </div>
                                <div className="flex flex-col ml-3">
                                    <div>
                                        Uploaded from Android device
                                    </div>
                                </div>
                            </div>
                        </div>
                    </div>
                </div>
            </div>
        </BrowserRouter>
    );
}