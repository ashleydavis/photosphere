import React, { useEffect, useState } from 'react';
import { NavLink } from 'react-router-dom';
import { useAssetDatabase } from '../context/asset-database-source';
import { usePlatform, type IDatabaseEntry } from '../context/platform-context';
import { useTheme } from '@mui/joy/styles/ThemeProvider';
import List from '@mui/joy/List/List';
import ListItem from '@mui/joy/ListItem/ListItem';
import ListItemDecorator from '@mui/joy/ListItemDecorator/ListItemDecorator';
import { PhotoLibrary, Folder, FolderOpen, Info, Map, Search, Settings, CreateNewFolder, FileUpload, ManageSearch, Key } from '@mui/icons-material';
import { CollapsibleSection } from './collapsible-section';
import ListItemContent from '@mui/joy/ListItemContent/ListItemContent';
import ListItemButton from '@mui/joy/ListItemButton/ListItemButton';
import Divider from '@mui/joy/Divider/Divider';
import { useSearch } from '../context/search-context';

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

    //
    // Opens the new database modal.
    //
    onNewDatabase: () => void;

    //
    // Opens the open database modal.
    //
    onOpenDatabase: () => void;
}


//
// Renders the left sidebar for the app.
//
export function LeftSidebar({ sidebarOpen, setSidebarOpen, onOpenConfiguration, onNewDatabase, onOpenDatabase }: ILeftSidebarProps) {
    const { setOpenSearch } = useSearch();
    const { openDatabase, databasePath } = useAssetDatabase();
    const platform = usePlatform();
    const theme = useTheme();
    // Recently opened databases (top 5).
    const [recentDatabases, setRecentDatabases] = useState<IDatabaseEntry[]>([]);

    function loadRecentDatabases(): void {
        platform.getRecentDatabases()
            .then(recent => setRecentDatabases(recent))
            .catch(err => console.error('Failed to load recent databases:', err));
    }

    useEffect(() => {
        loadRecentDatabases();
        return platform.onDatabaseOpened(() => loadRecentDatabases());
    }, [platform]);

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
                        onClick={() => {
                            setSidebarOpen(false);
                            onNewDatabase();
                        }}
                        >
                        <ListItemButton>
                            <ListItemDecorator><CreateNewFolder /></ListItemDecorator>
                            <ListItemContent>New database</ListItemContent>
                        </ListItemButton>
                    </ListItem>

                    <ListItem
                        onClick={() => {
                            setSidebarOpen(false);
                            onOpenDatabase();
                        }}
                        >
                        <ListItemButton>
                            <ListItemDecorator><FolderOpen /></ListItemDecorator>
                            <ListItemContent>Open database</ListItemContent>
                        </ListItemButton>
                    </ListItem>

                    {databasePath && (
                        <NavLink
                            to="/import"
                            onClick={() => setSidebarOpen(false)}
                            >
                            {({ isActive }) => (
                                <ListItem className={isActive ? "" : "opacity-40"}>
                                    <ListItemButton>
                                        <ListItemDecorator><FileUpload /></ListItemDecorator>
                                        <ListItemContent>Import</ListItemContent>
                                    </ListItemButton>
                                </ListItem>
                            )}
                        </NavLink>
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

            {recentDatabases.length > 0 && (
                <div className="flex flex-col">
                    <Divider />
                    <CollapsibleSection configKey="sidebar-collapsed-databases" label="Databases" style={{ paddingLeft: "15px" }}>
                        <List>
                            {recentDatabases.map(dbEntry => (
                                <ListItem key={dbEntry.path}>
                                    <ListItemButton
                                        onClick={async () => {
                                            setSidebarOpen(false);
                                            await openDatabase(dbEntry.path);
                                        }}
                                        >
                                        <ListItemDecorator>
                                            {dbEntry.path === databasePath
                                                ? <FolderOpen />
                                                : <Folder />
                                            }
                                        </ListItemDecorator>
                                        <ListItemContent title={dbEntry.path}>
                                            {dbEntry.name || dbEntry.path.split(/[\\/]/).filter(Boolean).pop() || dbEntry.path}
                                        </ListItemContent>
                                    </ListItemButton>
                                </ListItem>
                            ))}
                        </List>
                    </CollapsibleSection>
                </div>
            )}

            <div className="flex-grow" />

            <div className="flex flex-col">
                <Divider />
                <List sx={{ pl: "15px" }}>
                    <NavLink
                        to="/databases"
                        onClick={() => setSidebarOpen(false)}
                        >
                        {({ isActive }) => (
                            <ListItem className={isActive ? "" : "opacity-40"}>
                                <ListItemButton>
                                    <ListItemDecorator><ManageSearch /></ListItemDecorator>
                                    <ListItemContent>Manage Databases</ListItemContent>
                                </ListItemButton>
                            </ListItem>
                        )}
                    </NavLink>

                    <NavLink
                        to="/secrets"
                        onClick={() => setSidebarOpen(false)}
                        >
                        {({ isActive }) => (
                            <ListItem className={isActive ? "" : "opacity-40"}>
                                <ListItemButton>
                                    <ListItemDecorator><Key /></ListItemDecorator>
                                    <ListItemContent>Manage Secrets</ListItemContent>
                                </ListItemButton>
                            </ListItem>
                        )}
                    </NavLink>

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