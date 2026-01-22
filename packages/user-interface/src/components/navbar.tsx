import React from "react";
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
import Input from "@mui/joy/Input/Input";
import { useTheme } from "@mui/joy/styles/ThemeProvider";
import classNames from "classnames";
import { useSearch } from "../context/search-context";
import { useGallery } from "../context/gallery-context";
import { useAssetDatabase } from "../context/asset-database-source";
import { useApp } from "../context/app-context";
import { useDeleteConfirmation } from "../context/delete-confirmation-context";

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
    const { openSearch, setOpenSearch, searchInput, setSearchInput, onCommitSearch, onCloseSearch } = useSearch();
    const { sortedItems, selectedItems, clearMultiSelection, moveSelectedToDatabase } = useGallery();
    const { isLoading, databasePath } = useAssetDatabase();
    const { dbs } = useApp();
    const { setDeleteConfirmationOpen } = useDeleteConfirmation();

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
                        className="mr-1 sm:mr-3"
                        to="/cloud"
                    >
                        <div className="flex flex-row items-center">
                            <i className="w-5 text-center fa-solid fa-cloud"></i>
                            <div className="hidden sm:block ml-2">Cloud</div>
                        </div>
                    </NavLink>

                    <NavLink
                        className="mr-1 sm:mr-3"
                        to="/about"
                    >
                        <div className="flex flex-row items-center">
                            <i className="w-5 text-center fa-solid fa-circle-info"></i>
                            <div className="hidden sm:block ml-2">About</div>
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

                    {(selectedItemsCount > 0)
                        && <Dropdown>
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
                                    </>
                                }                                    
                            </Menu>
                        </Dropdown>
                    }
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
    );
}

