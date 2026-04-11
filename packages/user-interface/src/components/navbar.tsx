import React, { useEffect, useState } from "react";
import { NavLink } from "react-router-dom";
import { Spinner } from "./spinner";
import Dropdown from '@mui/joy/Dropdown';
import MenuButton from '@mui/joy/MenuButton';
import IconButton from '@mui/joy/IconButton';
import MoreVert from '@mui/icons-material/MoreVert';
import MenuItem from '@mui/joy/MenuItem';
import Menu from '@mui/joy/Menu';
import ListDivider from '@mui/joy/ListDivider';
import ListSubheader from "@mui/joy/ListSubheader";
import Delete from "@mui/icons-material/Delete";
import ExitToApp from "@mui/icons-material/ExitToApp";
import Star from "@mui/icons-material/Star";
import StarBorder from "@mui/icons-material/StarBorder";
import Input from "@mui/joy/Input/Input";
import { useTheme } from "@mui/joy/styles/ThemeProvider";
import classNames from "classnames";
import { useSearch } from "../context/search-context";
import { useDebounce } from "../lib/use-debounce";
import { useGallery } from "../context/gallery-context";
import { useAssetDatabase } from "../context/asset-database-source";
import { useApp } from "../context/app-context";
import { useDeleteConfirmation } from "../context/delete-confirmation-context";
import { usePlatform } from "../context/platform-context";
import type { IDownloadAssetItem } from "../context/platform-context";
import Download from "@mui/icons-material/Download";
import CalendarMonth from "@mui/icons-material/CalendarMonth";
import { useGallerySource } from "../context/gallery-source";
import { SetPhotoDateDialog } from "./set-photo-date-dialog";
import { SetLocationDialog } from "./set-location-dialog";

export interface INavbarProps {
    //
    // Set to true to open the sidebar.
    //
    sidebarOpen: boolean;
    setSidebarOpen: (open: boolean) => void;
}

//
// The navbar component for the Photosphere app.
//
export function Navbar({
    sidebarOpen,
    setSidebarOpen,
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
    const { sortedItems, selectedItems, clearMultiSelection, moveSelectedToDatabase, getItemById } = useGallery();
    const { isLoading, isSyncing, databasePath, closeDatabase } = useAssetDatabase();
    const { dbs } = useApp();
    const { setDeleteConfirmationOpen } = useDeleteConfirmation();
    const { downloadAssets } = usePlatform();
    const { updateAssets } = useGallerySource();

    //
    // Set to true to open the bulk set date dialog.
    //
    const [setDateDialogOpen, setSetDateDialogOpen] = useState<boolean>(false);

    //
    // Set to true to open the bulk set location dialog.
    //
    const [setLocationDialogOpen, setSetLocationDialogOpen] = useState<boolean>(false);

    const sortedItemsCount = sortedItems().length;
    const selectedItemsCount = selectedItems.size;

    //
    // Downloads all selected assets.
    //
    async function onDownloadSelected(): Promise<void> {
        const assets: IDownloadAssetItem[] = [];
        for (const assetId of selectedItems) {
            const item = getItemById(assetId);
            if (!item) {
                continue;
            }
            assets.push({ assetId, assetType: "asset", filename: item.origFileName || assetId, contentType: item.contentType });
        }
        await downloadAssets(assets, databasePath!);
    }

    //
    // Copies all selected assets (display version) to the clipboard.
    //
    //
    // Closes the current database.
    //
    async function onCloseDatabase() {
        clearMultiSelection();
        await closeDatabase();
    }

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
                        className="mr-1 sm:mr-3"
                        to="/gallery"
                    >
                        <div className="flex flex-row items-center">
                            <i className="w-5 text-center fa-solid fa-images"></i>
                            <div className="hidden sm:block ml-2">Gallery</div>
                        </div>
                    </NavLink>

                    <NavLink
                        className="mr-1 sm:mr-3"
                        to="/map"
                    >
                        <div className="flex flex-row items-center">
                            <i className="w-5 text-center fa-solid fa-map"></i>
                            <div className="hidden sm:block ml-2">Map</div>
                        </div>
                    </NavLink>

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

                    {databasePath && (
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
                                {selectedItemsCount > 0
                                    && <>
                                        <ListSubheader>MOVE TO</ListSubheader>
                                        {dbs.map(dbPath => {
                                            if (dbPath === databasePath) {
                                                return null; // Don't show the current database.
                                            }
                                            return (
                                                <MenuItem 
                                                    key={dbPath}
                                                    onClick={() => moveSelectedToDatabase(dbPath)}
                                                >
                                                    {dbPath}                                        
                                                </MenuItem>
                                            );
                                        })}
                                        <ListDivider />
                                        <MenuItem
                                            color="danger"
                                            onClick={() => setDeleteConfirmationOpen(true)}
                                        >
                                            <Delete />
                                            Delete {selectedItemsCount} assets
                                        </MenuItem>
                                        <ListDivider />
                                        <MenuItem onClick={onDownloadSelected}>
                                            <Download />
                                            Download {selectedItemsCount} assets
                                        </MenuItem>
                                        <ListDivider />
                                        <MenuItem onClick={() => setSetDateDialogOpen(true)}>
                                            <CalendarMonth />
                                            Set date for {selectedItemsCount} assets
                                        </MenuItem>
                                        <ListDivider />
                                        <MenuItem onClick={() => setSetLocationDialogOpen(true)}>
                                            <i className="fa-regular fa-map" style={{ width: "24px", textAlign: "center" }} />
                                            Set location for {selectedItemsCount} assets
                                        </MenuItem>
                                    </>
                                }                                    
                                {databasePath && (
                                    <>
                                        {selectedItemsCount > 0 && <ListDivider />}
                                        <MenuItem
                                            onClick={onCloseDatabase}
                                        >
                                            <ExitToApp />
                                            Close database
                                        </MenuItem>
                                    </>
                                )}
                            </Menu>
                        </Dropdown>
                    )}
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

            <SetPhotoDateDialog
                open={setDateDialogOpen}
                onClose={() => setSetDateDialogOpen(false)}
                onSetDate={async (date) => {
                    const assetUpdates = Array.from(selectedItems).map(assetId => ({
                        assetId,
                        partialAsset: { photoDate: date },
                    }));
                    await updateAssets(assetUpdates);
                    clearMultiSelection();
                    setSetDateDialogOpen(false);
                }}
                />

            <SetLocationDialog
                open={setLocationDialogOpen}
                onSetLocation={async (coordinates, location) => {
                    const assetUpdates = Array.from(selectedItems).map(assetId => ({
                        assetId,
                        partialAsset: { coordinates, location },
                    }));
                    await updateAssets(assetUpdates);
                    clearMultiSelection();
                    setSetLocationDialogOpen(false);
                }}
                onClearLocation={async () => {
                    const assetUpdates = Array.from(selectedItems).map(assetId => ({
                        assetId,
                        partialAsset: { coordinates: undefined, location: undefined },
                    }));
                    await updateAssets(assetUpdates);
                    clearMultiSelection();
                    setSetLocationDialogOpen(false);
                }}
                onClose={() => setSetLocationDialogOpen(false)}
                />

        </div>
    );
}

