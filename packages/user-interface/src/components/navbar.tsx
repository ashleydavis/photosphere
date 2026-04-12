import React, { useEffect, useState } from "react";
import { NavLink } from "react-router-dom";
import { Spinner } from "./spinner";
import IconButton from '@mui/joy/IconButton';
import MoreVert from '@mui/icons-material/MoreVert';
import Star from "@mui/icons-material/Star";
import StarBorder from "@mui/icons-material/StarBorder";
import FileUpload from "@mui/icons-material/FileUpload";
import Input from "@mui/joy/Input/Input";
import { useTheme } from "@mui/joy/styles/ThemeProvider";
import classNames from "classnames";
import { useSearch } from "../context/search-context";
import { useDebounce } from "../lib/use-debounce";
import { useGallery } from "../context/gallery-context";
import { useAssetDatabase } from "../context/asset-database-source";

export interface INavbarProps {
    //
    // Set to true to open the sidebar.
    //
    sidebarOpen: boolean;

    //
    // Sets the sidebar open or closed.
    //
    setSidebarOpen: (open: boolean) => void;

    //
    // Opens the configuration dialog.
    //
    onOpenConfiguration: () => void;

    //
    // Opens the right sidebar.
    //
    setRightSidebarOpen: (open: boolean) => void;
}

//
// The navbar component for the Photosphere app.
//
export function Navbar({
    sidebarOpen,
    setSidebarOpen,
    setRightSidebarOpen,
    onOpenConfiguration,
}: INavbarProps) {
    const theme = useTheme();
    const { openSearch, setOpenSearch, searchInput, onCommitSearch, onCloseSearch, savedSearches, saveSearch, unsaveSearch } = useSearch();

    //
    // Local input state so keystrokes don't re-render all context consumers.
    //
    const [draftSearchInput, setLocalInput] = useState<string>(searchInput);

    //
    // Debounce helper for the search input.
    //
    const searchDebounce = useDebounce(500);

    //
    // Sync local input when searchInput changes externally (e.g., search triggered from sidebar).
    //
    useEffect(() => {
        setLocalInput(searchInput);
    }, [searchInput]);
    const { sortedItems, selectedItems, clearMultiSelection } = useGallery();
    const { isLoading, isSyncing, databasePath } = useAssetDatabase();

    const sortedItemsCount = sortedItems().length;
    const selectedItemsCount = selectedItems.size;

    return (
        <div 
            id="navbar" 
            className={"select-none " + classNames({ "search": openSearch })}
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
                        className={({ isActive }) => "mr-1 sm:mr-3" + (isActive ? "" : " opacity-40")}
                        to="/gallery"
                    >
                        <div className="flex flex-row items-center">
                            <i className="w-5 text-center fa-solid fa-images"></i>
                            <div className="hidden sm:block ml-2">Gallery</div>
                        </div>
                    </NavLink>

                    <NavLink
                        className={({ isActive }) => "mr-1 sm:mr-3" + (isActive ? "" : " opacity-40")}
                        to="/map"
                    >
                        <div className="flex flex-row items-center">
                            <i className="w-5 text-center fa-solid fa-map"></i>
                            <div className="hidden sm:block ml-2">Map</div>
                        </div>
                    </NavLink>

                    {databasePath && (
                        <NavLink
                            className={({ isActive }) => "mr-1 sm:mr-3" + (isActive ? "" : " opacity-40")}
                            to="/import"
                        >
                            <div className="flex flex-row items-center">
                                <FileUpload fontSize="small" />
                                <div className="hidden sm:block ml-2">Import</div>
                            </div>
                        </NavLink>
                    )}

                    <div className="ml-auto"></div>

                    {(isLoading)
                        && <div className="flex flex-row items-center ml-1 mr-2">
                            <span className="text-sm hidden sm:block mr-1">Loading</span>
                            <div className="mx-1 sm:mx-2">
                                <Spinner show={true} />
                            </div>
                        </div>
                    }

                    {isSyncing && !isLoading
                        && <div className="flex flex-row items-center ml-1 mr-2">
                            <span className="text-sm hidden sm:block mr-1">Syncing</span>
                            <div className="mx-1 sm:mx-2">
                                <Spinner show={true} />
                            </div>
                        </div>
                    }

                    {databasePath && (
                        <div
                            className="flex flex-row items-center mr-2 text-xs sm:text-sm"
                        >
                            {selectedItemsCount > 0 
                                && <div className="flex flex-row items-center">
                                    <button
                                        className="w-6 text-sm"
                                        onClick={clearMultiSelection}
                                    >
                                        <i className="fa-solid fa-close"></i>
                                    </button>
                                    {selectedItemsCount} selected
                                </div>
                                || <div>{sortedItemsCount} photos</div>
                            }                        
                        </div>
                    )}

                    <IconButton
                        sx={{ mr: 1 }}
                        variant="soft"
                        color="neutral"
                        onClick={() => setRightSidebarOpen(true)}
                    >
                        <MoreVert />
                    </IconButton>
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
                            placeholder="Type to search..."
                            value={draftSearchInput}
                            onChange={event => {
                                const value = event.target.value;
                                setLocalInput(value);
                                searchDebounce.schedule(() => onCommitSearch(value));
                            }}
                            onKeyDown={async event => {
                                if (event.key === "Enter") {
                                    //
                                    // Commits the search immediately, cancelling any pending debounce.
                                    //
                                    searchDebounce.cancel();
                                    await onCommitSearch(draftSearchInput);
                                }
                                else if (event.key === "Escape") {
                                    //
                                    // Cancels the search.
                                    //
                                    searchDebounce.cancel();
                                    await onCloseSearch();
                                }
                            }}
                        />
                        {draftSearchInput.trim().length > 0 && (
                            <IconButton
                                size="sm"
                                variant="plain"
                                color="neutral"
                                title={savedSearches.includes(draftSearchInput.trim()) ? "Unsave search" : "Save search"}
                                onClick={async () => {
                                    if (savedSearches.includes(draftSearchInput.trim())) {
                                        await unsaveSearch(draftSearchInput.trim());
                                    }
                                    else {
                                        await saveSearch(draftSearchInput.trim());
                                    }
                                }}
                            >
                                {savedSearches.includes(draftSearchInput.trim())
                                    ? <Star fontSize="small" />
                                    : <StarBorder fontSize="small" />
                                }
                            </IconButton>
                        )}
                        <a
                            className="w-10 text-xl text-center"
                            href="https://github.com/ashleydavis/photosphere/wiki/Gallery-Search"
                            target="_blank"
                            rel="noreferrer"
                            title="Search help"
                        >
                            <i className="fa-solid fa-circle-question"></i>
                        </a>
                        <button
                            className="w-10 text-xl"
                            onClick={() => {
                                searchDebounce.cancel();
                                onCloseSearch();
                            }}
                        >
                            <i className="fa-solid fa-close"></i>
                        </button>
                    </div>
                }                    
            </div>

        </div>
    );
}

