import { log } from "utils";
import React, { useEffect, useState } from 'react';
import { NavLink, useLocation, useNavigate } from 'react-router-dom';
import { useAssetDatabase } from '../context/asset-database-source';
import { usePlatform, type IDatabaseEntry } from '../context/platform-context';
import Box from '@mui/material/Box';
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
// The look of the rows of both sidebars, from the sidebar row tokens: the room round the rows, the
// gap between them, their corners, the bar down the left edge of the current row and their icons,
// muted at rest and in the current-page colour on the current row. The right sidebar uses it too,
// so both sidebars' rows look alike.
//
export const SIDEBAR_ROWS_STYLE = {
    padding: "var(--sidebar-list-padding)",
    "& .MuiList-root": {
        display: "flex",
        flexDirection: "column",
        gap: "var(--space-1)",
        padding: "0 0 var(--space-2)",
    },
    "& .MuiListItemButton-root": {
        borderRadius: "var(--sidebar-row-radius)",
    },
    "& .MuiListItemButton-root.Mui-selected, & .MuiListItemButton-root.Mui-selected:hover": {
        boxShadow: "inset var(--sidebar-current-bar-width) 0 0 var(--color-sidebar-current-bar)",
    },
    "& .MuiListItemIcon-root": {
        minWidth: 0,
        color: "var(--color-text-muted)",
        fontSize: "var(--icon-md)",
    },
    "& .MuiListItemIcon-root .MuiSvgIcon-root": {
        fontSize: "var(--icon-lg)",
    },
    "& .MuiListItemIcon-root > i": {
        width: "var(--icon-lg)",
        textAlign: "center",
    },
    "& .Mui-selected .MuiListItemIcon-root": {
        color: "var(--color-nav-current-text)",
    },
    "& .MuiListItemButton-root > .MuiSvgIcon-root": {
        fontSize: "var(--icon-lg)",
        color: "var(--color-text-muted)",
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
        // Fills its container (the drawer) rather than forcing a full viewport height. The header
        // stays put and the rows under it scroll when they are taller than the drawer, so the rows
        // pinned to its bottom (About, Manage Databases, Manage Secrets) can still be reached once
        // enough recent databases are listed.
        //
        <div className="flex flex-col h-full">
            <div
                className="flex flex-row items-center"
                style={{
                    gap: "var(--space-3)",
                    padding: "var(--space-3) var(--space-3) var(--space-2) var(--space-4)",
                }}
                >
                <span
                    aria-hidden={true}
                    className="flex items-center justify-center"
                    style={{
                        width: "var(--button-height-sm)",
                        height: "var(--button-height-sm)",
                        flex: "none",
                        borderRadius: "var(--radius-sm)",
                        background: "var(--empty-icon-bg)",
                        color: "var(--color-empty-icon)",
                    }}
                    >
                    <PhotoLibrary
                        sx={{
                            fontSize: "var(--icon-md)",
                        }}
                        />
                </span>
                <h1
                    className="flex-1"
                    style={{
                        fontFamily: "var(--font-heading)",
                        fontSize: "var(--text-lg)",
                        fontWeight: "var(--weight-bold)",
                    }}
                    >
                    Photosphere
                </h1>
                <IconButton
                    title="Close sidebar"
                    onClick={() => setSidebarOpen(!sidebarOpen)}
                    >
                    <i
                        className="fa-solid fa-arrow-left"
                        style={{
                            fontSize: "var(--icon-md)",
                        }}
                        />
                </IconButton>
            </div>

            <Box
                className="flex flex-col min-h-0 flex-1 overflow-y-auto"
                sx={{
                    ...SIDEBAR_ROWS_STYLE,
                    overscrollBehavior: "contain",
                }}
                >
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

                    <Divider
                        component="li"
                        sx={{
                            margin: "var(--space-1) 0",
                        }}
                        />

                    {databasePath && (
                        <NavLink
                            to="/import"
                            data-id="sidebar-import"
                            onClick={() => setSidebarOpen(false)}
                            >
                            {({ isActive }) => (
                                <ListItem disablePadding>
                                    <ListItemButton selected={isActive}>
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
                            <ListItem disablePadding>
                                <ListItemButton selected={isActive}>
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
                            <ListItem disablePadding>
                                <ListItemButton selected={isActive}>
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
                                <ListItem disablePadding>
                                    <ListItemButton selected={isActive}>
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
                            <ListItem disablePadding>
                                <ListItemButton selected={true}>
                                    <ListItemIcon><TemporaryNavPageIcon /></ListItemIcon>
                                    <ListItemText>{temporaryNavPage.label}</ListItemText>
                                </ListItemButton>
                            </ListItem>
                        </NavLink>
                    )}

                </List>

                {recentDatabases.length > 0 && (
                    <div className="flex flex-col">
                        <CollapsibleSection configKey="sidebar-collapsed-databases" label="Databases">
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
                                                sx={{
                                                    minHeight: "var(--button-height-sm)",
                                                    minWidth: "var(--button-height-sm)",
                                                }}
                                                >
                                                <Delete
                                                    sx={{
                                                        fontSize: "var(--icon-lg)",
                                                    }}
                                                    />
                                            </IconButton>
                                        }
                                        >
                                        <ListItemButton
                                            data-id={`open-recent-database-button-${dbIndex}`}
                                            selected={dbEntry.path === databasePath}
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
                                                <CircularProgress data-id={`open-recent-database-spinner-${dbIndex}`} size="var(--icon-lg)" />
                                            )}
                                        </ListItemButton>
                                    </ListItem>
                                ))}
                            </List>
                        </CollapsibleSection>
                    </div>
                )}

                <div className="flex-grow" />

                <List>
                    <Divider
                        component="li"
                        sx={{
                            margin: "var(--space-1) 0",
                        }}
                        />
                    <NavLink
                        to="/about"
                        onClick={() => setSidebarOpen(false)}
                        >
                        {({ isActive }) => (
                            <ListItem disablePadding>
                                <ListItemButton selected={isActive}>
                                    <ListItemIcon><i className="fa-solid fa-circle-info" /></ListItemIcon>
                                    <ListItemText>About</ListItemText>
                                </ListItemButton>
                            </ListItem>
                        )}
                    </NavLink>
                    <NavLink
                        to="/databases"
                        data-id="sidebar-manage-databases"
                        onClick={() => setSidebarOpen(false)}
                        >
                        {({ isActive }) => (
                            <ListItem disablePadding>
                                <ListItemButton selected={isActive}>
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
                            <ListItem disablePadding>
                                <ListItemButton selected={isActive}>
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
                                <ListItem disablePadding>
                                    <ListItemButton selected={isActive}>
                                        <ListItemIcon><DeveloperMode /></ListItemIcon>
                                        <ListItemText>Developer</ListItemText>
                                    </ListItemButton>
                                </ListItem>
                            )}
                        </NavLink>
                    )}
                </List>
            </Box>

        </div>
    );

}
