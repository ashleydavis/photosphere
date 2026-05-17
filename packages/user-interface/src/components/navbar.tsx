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
import { useToast } from "../context/toast-context";
import { usePlatform } from "../context/platform-context";

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

    //
    // The latest available release version, when newer than the running build.
    //
    const [updateVersion, setUpdateVersion] = useState<string | undefined>(undefined);

    const { addToast } = useToast();
    const platform = usePlatform();

    //
    // Subscribe to update-available IPC events fired by the desktop main process.
    // The main process handles the GitHub fetch and the comparison against the running
    // build, so the renderer only sees this callback when there is a genuinely new
    // version to announce. We (a) show the persistent pill rendered further down, and
    // (b) fire a one-off primary-coloured toast so the user notices on startup. The
    // version is persisted in `last_shown_update_version` only when the user clicks
    // the toast's close button (via `markUpdateAsShown`); closing the app without
    // dismissing causes the notification to re-fire next startup. On web/mobile this
    // never fires (no main process); update flow there is via the host store.
    //
    useEffect(() => {
        const unsubscribe = platform.onUpdateAvailable(({ latestVersion }) => {
            setUpdateVersion(latestVersion);
            addToast({
                message: `A new version of Photosphere is available: v${latestVersion}`,
                color: 'primary',
                duration: 0,
                action: {
                    label: 'Download',
                    onClick: () => window.open('https://github.com/ashleydavis/photosphere/releases/latest', '_blank', 'noopener'),
                },
                onDismiss: () => {
                    platform.markUpdateAsShown(latestVersion);
                },
            });
        });
        return unsubscribe;
    }, [platform, addToast]);
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
                        data-id="sidebar-toggle-button"
                        title="Toggle sidebar"
                        onClick={() => setSidebarOpen(!sidebarOpen)}
                    >
                        <i className="fa-solid fa-bars"></i>
                    </button>

                    <h1 className="ml-3 sm:ml-4">Photosphere</h1>

                    <button
                        className="ml-4 mr-1 sm:ml-8 sm:mr-3"
                        title="Search"
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
                                        title="Clear selection"
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

                    {updateVersion && (
                        <a
                            data-id="update-available-badge"
                            className="mr-2"
                            href="https://github.com/ashleydavis/photosphere/releases/latest"
                            target="_blank"
                            rel="noreferrer"
                            title="A new version of Photosphere is available"
                            style={{
                                display: 'inline-flex',
                                alignItems: 'center',
                                padding: '2px 8px',
                                borderRadius: '999px',
                                fontSize: '0.75rem',
                                backgroundColor: theme.palette.success.softBg,
                                color: theme.palette.success.softColor,
                                textDecoration: 'none',
                            }}
                        >
                            v{updateVersion} available
                        </a>
                    )}

                    <IconButton
                        sx={{ mr: 1 }}
                        variant="soft"
                        color="neutral"
                        title="Open menu"
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
                            title="Close search"
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

