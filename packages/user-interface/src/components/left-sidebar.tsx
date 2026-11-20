import { log } from "utils";
import React, { useEffect, useState } from 'react';
import { NavLink, useLocation, useNavigate } from 'react-router-dom';
import { useAssetDatabase } from '../context/asset-database-source';
import { usePlatform, type IDatabaseEntry } from '../context/platform-context';
import { useTheme } from '@mui/material/styles';
import List from '@mui/material/List';
import ListItem from '@mui/material/ListItem';
import ListItemIcon from '@mui/material/ListItemIcon';
import { PhotoLibrary, Folder, FolderOpen, Map, Search, Settings, CreateNewFolder, LibraryAdd, FileUpload, ManageSearch, Key, Delete, DeveloperMode, Storage } from '@mui/icons-material';
import { CollapsibleSection } from './collapsible-section';
import ListItemText from '@mui/material/ListItemText';
import ListItemButton from '@mui/material/ListItemButton';
import IconButton from '@mui/material/IconButton';
import CircularProgress from '@mui/material/CircularProgress';
import Divider from '@mui/material/Divider';
import { useSearch } from '../context/search-context';
import { useDeveloper } from '../context/developer-context';
import { findTemporaryNavPage } from '../lib/nav-pages';

//
// Styling applied to the active sidebar navigation item so it stands out
// (bold text and an accent colour for both the label and icon). MUI's
// ListItemIcon and the label's Typography set their own colour and weight, so
// the accent must override them directly via `sx` rather than rely on a parent
// Tailwind class. This matches the active link treatment in the navbar
// (Tailwind's sky-500).
//
const activeNavItemSx = {
    //
    // Accent colour for the button label.
    //
    "& .MuiListItemButton-root": {
        color: "rgb(14 165 233)",
    },

    //
    // Bold weight for the label text.
    //
    "& .MuiListItemText-primary": {
        fontWeight: 600,
    },

    //
    // Apply the same accent colour to the decorator icon.
    //
    "& svg": {
        color: "rgb(14 165 233)",
    },
};

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
    // Opens the add database modal.
    //
    onAddDatabase: () => void;
}


//
// Renders the left sidebar for the app.
//
export function LeftSidebar({ sidebarOpen, setSidebarOpen, onOpenConfiguration, onNewDatabase, onAddDatabase }: ILeftSidebarProps) {
    const { setOpenSearch } = useSearch();
    const { developerMode } = useDeveloper();
    const { openDatabase, databasePath, isOpening } = useAssetDatabase();
    const platform = usePlatform();
    const theme = useTheme();
    const location = useLocation();
    const navigate = useNavigate();
    // The current location, used to show a temporary sidebar entry for pages
    // that have no permanent sidebar link.
    const temporaryNavPage = findTemporaryNavPage(location.pathname, ["/gallery", "/map", "/import", "/databases", "/secrets", "/about"]);
    const TemporaryNavPageIcon = temporaryNavPage?.icon;
    // Recently opened databases (top 5).
    const [recentDatabases, setRecentDatabases] = useState<IDatabaseEntry[]>([]);
    // The path of the recent database the user tapped, so the spinner shows on that one alone.
    const [openingPath, setOpeningPath] = useState<string | undefined>(undefined);

    function loadRecentDatabases(): void {
        platform.getRecentDatabases()
            .then(recent => setRecentDatabases(recent))
            .catch(err => log.exception('Failed to load recent databases:', err as Error));
    }

    useEffect(() => {
        loadRecentDatabases();
        return platform.onDatabaseOpened(() => loadRecentDatabases());
    }, [platform]);

    return (
        //
        // Fills its container (the drawer) rather than forcing a full viewport height, and scrolls
        // when the content is taller than that. With a fixed 100vh height the sidebar overflows any
        // container shorter than the viewport, and with no scrolling the items pinned to its bottom
        // (About, Manage Databases, Manage Secrets) fall off the bottom edge and cannot be reached
        // once enough recent databases are listed.
        //
        <div
            className="flex flex-col h-full overflow-y-auto"
            style={{
                color: (theme.vars ?? theme).palette.text.primary,
            }}
            >
            <div className="flex flex-row items-center mt-4" style={{ paddingLeft: "15px" }}>
                <h1 className="text-xl">
                    Photosphere
                </h1>
                <div className="flex-grow" />
                <button
                    className="mr-3 text-xl"
                    title="Close sidebar"
                    onClick={() => setSidebarOpen(!sidebarOpen)}
                    >
                    <i className="fa-solid fa-arrow-left"></i>
                </button>
            </div>

            <div className="flex flex-col" style={{ paddingLeft: "15px" }}>
                <List>
                    <ListItem
                        disablePadding
                        data-id="sidebar-new-database"
                        onClick={() => {
                            setSidebarOpen(false);
                            onNewDatabase();
                        }}
                        >
                        <ListItemButton>
                            <ListItemIcon><CreateNewFolder /></ListItemIcon>
                            <ListItemText>New database</ListItemText>
                        </ListItemButton>
                    </ListItem>

                    <ListItem
                        disablePadding
                        onClick={() => {
                            setSidebarOpen(false);
                            onAddDatabase();
                        }}
                        >
                        <ListItemButton>
                            <ListItemIcon><LibraryAdd /></ListItemIcon>
                            <ListItemText>Add database</ListItemText>
                        </ListItemButton>
                    </ListItem>

                    <ListItem
                        disablePadding
                        data-id="sidebar-open-database"
                        onClick={() => {
                            setSidebarOpen(false);
                            platform.runAction("open-database")
                                .catch(err => log.exception('Failed to open the Open Database dialog:', err as Error));
                        }}
                        >
                        <ListItemButton>
                            <ListItemIcon><FolderOpen /></ListItemIcon>
                            <ListItemText>Open database</ListItemText>
                        </ListItemButton>
                    </ListItem>

                    {databasePath && (
                        <NavLink
                            to="/import"
                            data-id="sidebar-import"
                            onClick={() => setSidebarOpen(false)}
                            >
                            {({ isActive }) => (
                                <ListItem disablePadding sx={isActive ? activeNavItemSx : undefined}>
                                    <ListItemButton>
                                        <ListItemIcon><FileUpload /></ListItemIcon>
                                        <ListItemText>Import</ListItemText>
                                    </ListItemButton>
                                </ListItem>
                            )}
                        </NavLink>
                    )}


                    <ListItem
                        disablePadding
                        onClick={() => {
                            setSidebarOpen(false);
                            navigate("/gallery");
                            setTimeout(() => { // Delay the opening of the search input allows it auto focus.
                                setOpenSearch(true);
                            }, 10);
                        }}
                        >
                        <ListItemButton>
                            <ListItemIcon><Search /></ListItemIcon>
                            <ListItemText>Search</ListItemText>
                        </ListItemButton>
                    </ListItem>

                    <NavLink
                        to="/gallery"
                        onClick={() => setSidebarOpen(false)}
                        >
                        {({ isActive }) => (
                            <ListItem disablePadding sx={isActive ? activeNavItemSx : undefined}>
                                <ListItemButton>
                                    <ListItemIcon><PhotoLibrary /></ListItemIcon>
                                    <ListItemText>Gallery</ListItemText>
                                </ListItemButton>
                            </ListItem>
                        )}
                    </NavLink>

                    <NavLink
                        to="/map"
                        onClick={() => setSidebarOpen(false)}
                        >
                        {({ isActive }) => (
                            <ListItem disablePadding sx={isActive ? activeNavItemSx : undefined}>
                                <ListItemButton>
                                    <ListItemIcon><Map /></ListItemIcon>
                                    <ListItemText>Map</ListItemText>
                                </ListItemButton>
                            </ListItem>
                        )}
                    </NavLink>

                    {databasePath && (
                        <NavLink
                            to="/database-summary"
                            data-id="sidebar-database-summary"
                            onClick={() => setSidebarOpen(false)}
                            >
                            {({ isActive }) => (
                                <ListItem disablePadding sx={isActive ? activeNavItemSx : undefined}>
                                    <ListItemButton>
                                        <ListItemIcon><Storage /></ListItemIcon>
                                        <ListItemText>Database Info</ListItemText>
                                    </ListItemButton>
                                </ListItem>
                            )}
                        </NavLink>
                    )}

                    {temporaryNavPage && TemporaryNavPageIcon && (
                        <NavLink
                            to={temporaryNavPage.path}
                            onClick={() => setSidebarOpen(false)}
                            >
                            <ListItem disablePadding sx={activeNavItemSx}>
                                <ListItemButton>
                                    <ListItemIcon><TemporaryNavPageIcon /></ListItemIcon>
                                    <ListItemText>{temporaryNavPage.label}</ListItemText>
                                </ListItemButton>
                            </ListItem>
                        </NavLink>
                    )}

                </List>
            </div>

            {recentDatabases.length > 0 && (
                <div className="flex flex-col">
                    <Divider />
                    <CollapsibleSection configKey="sidebar-collapsed-databases" label="Databases" style={{ paddingLeft: "15px" }}>
                        <List>
                            {recentDatabases.map((dbEntry, dbIndex) => (
                                <ListItem
                                    disablePadding
                                    key={dbEntry.name}
                                    secondaryAction={
                                        <IconButton
                                            data-id={`remove-recent-database-button-${dbIndex}`}
                                            size="small"
                                            color="default"
                                            title="Remove from recent databases"
                                            onClick={async (clickEvent) => {
                                                clickEvent.stopPropagation();
                                                await platform.removeRecentDatabaseName(dbEntry.name);
                                                loadRecentDatabases();
                                            }}
                                            sx={{ minHeight: '32px', minWidth: '32px' }}
                                            >
                                            <Delete fontSize="small" />
                                        </IconButton>
                                    }
                                    >
                                    <ListItemButton
                                        data-id={`open-recent-database-button-${dbIndex}`}
                                        // Every entry goes dead while an open is under way, so a
                                        // second open cannot be started on top of the first.
                                        disabled={isOpening}
                                        // The sidebar is closed once the open has resolved rather
                                        // than on the tap. Closing it first hides the only thing
                                        // saying anything is happening, and an open takes seconds.
                                        onClick={async () => {
                                            setOpeningPath(dbEntry.path);
                                            await openDatabase(dbEntry.path);
                                            setSidebarOpen(false);
                                        }}
                                        >
                                        <ListItemIcon>
                                            {dbEntry.path === databasePath
                                                ? <FolderOpen />
                                                : <Folder />
                                            }
                                        </ListItemIcon>
                                        <ListItemText data-id={`recent-database-name-${dbIndex}`} title={dbEntry.path}>
                                            {dbEntry.name || dbEntry.path.split(/[\\/]/).filter(Boolean).pop() || dbEntry.path}
                                        </ListItemText>
                                        {isOpening && openingPath === dbEntry.path && (
                                            <CircularProgress data-id={`open-recent-database-spinner-${dbIndex}`} size={24} />
                                        )}
                                    </ListItemButton>
                                </ListItem>
                            ))}
                        </List>
                    </CollapsibleSection>
                </div>
            )}

            <div className="flex-grow" />

            <div className="flex flex-col">
                <List sx={{ pl: "15px" }}>
                    <NavLink
                        to="/about"
                        onClick={() => setSidebarOpen(false)}
                        >
                        {({ isActive }) => (
                            <ListItem disablePadding sx={isActive ? activeNavItemSx : undefined}>
                                <ListItemButton>
                                    <ListItemIcon><i className="fa-solid fa-circle-info" /></ListItemIcon>
                                    <ListItemText>About</ListItemText>
                                </ListItemButton>
                            </ListItem>
                        )}
                    </NavLink>
                </List>
                <Divider />
                <List sx={{ pl: "15px" }}>
                    <NavLink
                        to="/databases"
                        data-id="sidebar-manage-databases"
                        onClick={() => setSidebarOpen(false)}
                        >
                        {({ isActive }) => (
                            <ListItem disablePadding sx={isActive ? activeNavItemSx : undefined}>
                                <ListItemButton>
                                    <ListItemIcon><ManageSearch /></ListItemIcon>
                                    <ListItemText>Manage Databases</ListItemText>
                                </ListItemButton>
                            </ListItem>
                        )}
                    </NavLink>

                    <NavLink
                        to="/secrets"
                        onClick={() => setSidebarOpen(false)}
                        >
                        {({ isActive }) => (
                            <ListItem disablePadding sx={isActive ? activeNavItemSx : undefined}>
                                <ListItemButton>
                                    <ListItemIcon><Key /></ListItemIcon>
                                    <ListItemText>Manage Secrets</ListItemText>
                                </ListItemButton>
                            </ListItem>
                        )}
                    </NavLink>

                    <ListItem
                        disablePadding
                        data-id="sidebar-configuration"
                        onClick={() => {
                            setSidebarOpen(false);
                            onOpenConfiguration();
                        }}
                        >
                        <ListItemButton>
                            <ListItemIcon><Settings /></ListItemIcon>
                            <ListItemText>Configuration</ListItemText>
                        </ListItemButton>
                    </ListItem>

                    {developerMode && (
                        <NavLink
                            to="/developer"
                            data-id="sidebar-developer"
                            onClick={() => setSidebarOpen(false)}
                            >
                            {({ isActive }) => (
                                <ListItem disablePadding sx={isActive ? activeNavItemSx : undefined}>
                                    <ListItemButton>
                                        <ListItemIcon><DeveloperMode /></ListItemIcon>
                                        <ListItemText>Developer</ListItemText>
                                    </ListItemButton>
                                </ListItem>
                            )}
                        </NavLink>
                    )}
                </List>
            </div>

        </div>
    );

}
