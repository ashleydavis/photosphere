import React from 'react';
import { NavLink } from 'react-router-dom';
import { useApp } from '../context/app-context';
import { useAssetDatabase } from '../context/asset-database-source';
import { useTheme } from '@mui/joy/styles/ThemeProvider';
import List from '@mui/joy/List/List';
import ListItem from '@mui/joy/ListItem/ListItem';
import ListItemDecorator from '@mui/joy/ListItemDecorator/ListItemDecorator';
import { PhotoLibrary, Folder, FolderOpen, Info, Map, Search, Settings, Star, StarBorder, Delete, CreateNewFolder, FileUpload } from '@mui/icons-material';
import { CollapsibleSection } from './collapsible-section';
import ListItemContent from '@mui/joy/ListItemContent/ListItemContent';
import ListItemButton from '@mui/joy/ListItemButton/ListItemButton';
import IconButton from '@mui/joy/IconButton/IconButton';
import Divider from '@mui/joy/Divider/Divider';
import { useGallery } from '../context/gallery-context';
import { useSearch } from '../context/search-context';
import { usePlatform } from '../context/platform-context';

export interface ILeftSidebarProps {
    //
    // True if the sidebar is open.
    //
    sidebarOpen: boolean;

    //
    // Sets the sidebar open or close.
    //
    setSidebarOpen: (open: boolean) => void;

    //
    // Opens the configuration dialog.
    //
    onOpenConfiguration: () => void;
}


//
// Renders the left sidebar for the app.
//
export function LeftSidebar({ sidebarOpen, setSidebarOpen, onOpenConfiguration }: ILeftSidebarProps) {
    const { setOpenSearch, savedSearches, saveSearch, unsaveSearch } = useSearch();
    const { openDatabase } = useAssetDatabase();

    const { dbs, removeDatabase } = useApp();
    const theme = useTheme();
    const { databasePath, selectAndOpenDatabase, selectAndCreateDatabase } = useAssetDatabase();
    const { search } = useGallery();
    const { importAssets } = usePlatform();

    return (
        <div
            className="flex flex-col h-screen"
            style={{
                color: theme.palette.text.primary,
            }}
            >
            <div className="flex flex-row items-center mt-4" style={{ paddingLeft: "15px" }}>
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

            <div className="flex flex-col" style={{ paddingLeft: "15px" }}>
                <List>
                    <ListItem
                        onClick={async () => {
                            setSidebarOpen(false);
                            await selectAndCreateDatabase();
                        }}
                        >
                        <ListItemButton>
                            <ListItemDecorator><CreateNewFolder /></ListItemDecorator>
                            <ListItemContent>New database</ListItemContent>
                        </ListItemButton>
                    </ListItem>

                    <ListItem
                        onClick={async () => {
                            setSidebarOpen(false);
                            await selectAndOpenDatabase();
                        }}
                        >
                        <ListItemButton>
                            <ListItemDecorator><FolderOpen /></ListItemDecorator>
                            <ListItemContent>Open database</ListItemContent>
                        </ListItemButton>
                    </ListItem>

                    {databasePath && (
                        <ListItem
                            onClick={async () => {
                                setSidebarOpen(false);
                                await importAssets();
                            }}
                            >
                            <ListItemButton>
                                <ListItemDecorator><FileUpload /></ListItemDecorator>
                                <ListItemContent>Import photos</ListItemContent>
                            </ListItemButton>
                        </ListItem>
                    )}

                    <ListItem
                        onClick={() => {
                            setSidebarOpen(false);
                            setTimeout(() => { // Delay the opening of the search input allows it auto focus.
                                setOpenSearch(true);
                            }, 10);
                        }}
                        >
                        <ListItemButton>
                            <ListItemDecorator><Search /></ListItemDecorator>
                            <ListItemContent>Search</ListItemContent>
                        </ListItemButton>
                    </ListItem>

                    <NavLink
                        to="/gallery"
                        onClick={() => setSidebarOpen(false)}
                        >
                        {({ isActive }) => (
                            <ListItem className={isActive ? "" : "opacity-40"}>
                                <ListItemButton>
                                    <ListItemDecorator><PhotoLibrary /></ListItemDecorator>
                                    <ListItemContent>Gallery</ListItemContent>
                                </ListItemButton>
                            </ListItem>
                        )}
                    </NavLink>

                    <NavLink
                        to="/map"
                        onClick={() => setSidebarOpen(false)}
                        >
                        {({ isActive }) => (
                            <ListItem className={isActive ? "" : "opacity-40"}>
                                <ListItemButton>
                                    <ListItemDecorator><Map /></ListItemDecorator>
                                    <ListItemContent>Map</ListItemContent>
                                </ListItemButton>
                            </ListItem>
                        )}
                    </NavLink>

                    <NavLink
                        to="/about"
                        onClick={() => setSidebarOpen(false)}
                        >
                        {({ isActive }) => (
                            <ListItem className={isActive ? "" : "opacity-40"}>
                                <ListItemButton>
                                    <ListItemDecorator><Info /></ListItemDecorator>
                                    <ListItemContent>About</ListItemContent>
                                </ListItemButton>
                            </ListItem>
                        )}
                    </NavLink>
                </List>
            </div>

            {savedSearches.length > 0 &&
                <div className="flex flex-col">
                    <Divider />
                    <CollapsibleSection configKey="sidebar-collapsed-savedSearches" label="Saved Searches" style={{ paddingLeft: "15px" }}>
                        <List>
                            {savedSearches.map(savedSearch => (
                                <ListItem
                                    key={savedSearch}
                                    endAction={
                                        <IconButton
                                            size="sm"
                                            variant="plain"
                                            color="neutral"
                                            onClick={async (e) => {
                                                e.stopPropagation();
                                                await unsaveSearch(savedSearch);
                                            }}
                                            sx={{ minHeight: '32px', minWidth: '32px' }}
                                        >
                                            <Star fontSize="small" sx={{ color: "gold" }} />
                                        </IconButton>
                                    }
                                    >
                                    <ListItemButton
                                        onClick={() => {
                                            search(savedSearch);
                                            setSidebarOpen(false);
                                        }}
                                        >
                                        <ListItemDecorator><StarBorder /></ListItemDecorator>
                                        <ListItemContent>{savedSearch}</ListItemContent>
                                    </ListItemButton>
                                </ListItem>
                            ))}
                        </List>
                    </CollapsibleSection>
                </div>
            }

            <div className="flex flex-col">
                <Divider />
                <CollapsibleSection configKey="sidebar-collapsed-databases" label="Databases" style={{ paddingLeft: "15px" }}>
                    <List>
                        {dbs.map(dbPath => {
                            return (
                                <ListItem
                                    key={dbPath}
                                    endAction={
                                        <IconButton
                                            size="sm"
                                            variant="plain"
                                            color="neutral"
                                            onClick={async (e) => {
                                                e.stopPropagation();
                                                await removeDatabase(dbPath);
                                            }}
                                            sx={{ minHeight: '32px', minWidth: '32px' }}
                                        >
                                            <Delete fontSize="small" />
                                        </IconButton>
                                    }
                                    >
                                    <ListItemButton
                                        onClick={async () => {
                                            setSidebarOpen(false);
                                            await openDatabase(dbPath);
                                        }}
                                        >
                                        <ListItemDecorator>
                                            {dbPath === databasePath
                                                ? <FolderOpen />
                                                : <Folder />
                                            }
                                        </ListItemDecorator>
                                        <ListItemContent title={dbPath}>{dbPath.split(/[\\/]/).filter(Boolean).pop() ?? dbPath}</ListItemContent>
                                    </ListItemButton>
                                </ListItem>
                            );
                        })}
                    </List>
                </CollapsibleSection>
            </div>

            <div className="flex-grow" />

            <div className="flex flex-col">
                <Divider />
                <List sx={{ pl: "15px" }}>
                    <ListItem
                        onClick={() => {
                            setSidebarOpen(false);
                            onOpenConfiguration();
                        }}
                        >
                        <ListItemButton>
                            <ListItemDecorator><Settings /></ListItemDecorator>
                            <ListItemContent>Configuration</ListItemContent>
                        </ListItemButton>
                    </ListItem>
                </List>
            </div>
        </div>
    );

}