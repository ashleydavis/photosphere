import Typography from '@mui/material/Typography';
import React, { useEffect, useRef, useState } from 'react';
import { useApp } from '../context/app-context';
import { useAssetDatabase } from '../context/asset-database-source';
import Box from '@mui/material/Box';
import Button from '@mui/material/Button';
import List from '@mui/material/List';
import ListItem from '@mui/material/ListItem';
import ListItemIcon from '@mui/material/ListItemIcon';
import { ArrowForward, CalendarMonth, Category, DateRange, Delete, ExitToApp, Flag, Home, KeyboardArrowRight, Map, MoreHoriz, Place, Search, Star, StarBorder, History } from '@mui/icons-material';
import { useIsMobile } from '../lib/use-is-mobile';
import { CollapsibleSection } from './collapsible-section';
import ListItemText from '@mui/material/ListItemText';
import ListItemButton from '@mui/material/ListItemButton';
import IconButton from '@mui/material/IconButton';
import Breadcrumbs from '@mui/material/Breadcrumbs';
import Link from '@mui/material/Link';
import { SIDEBAR_ROWS_STYLE } from './left-sidebar';
import { useGalleryLayout } from '../context/gallery-layout-context';
import { IGalleryLayout } from '../lib/create-layout';
import { useGallery } from '../context/gallery-context';
import { useSearch } from '../context/search-context';
import dayjs from 'dayjs';
import { useDeleteConfirmation } from '../context/delete-confirmation-context';
import type { IDownloadAssetItem } from '../context/platform-context';
import { useGallerySource } from '../context/gallery-source';
import { SetPhotoDateDialog } from './set-photo-date-dialog';
import { SetLocationDialog } from './set-location-dialog';
import Download from '@mui/icons-material/Download';

export interface IRightSidebarProps {
    //
    // True if the sidebar is open.
    //
    sidebarOpen: boolean;

    //
    // Sets the sidebar open or close.
    //
    setSidebarOpen: (open: boolean) => void;

}

//
// Defines a menu item in the sidebar menu.
//
interface IMenuItem {
    //
    // The icon for the menu item.
    //
    icon?: React.JSX.Element;

    //
    // The text for the menu item.
    //
    text: string;

    //
    // The children of the menu item.
    //
    children?: IMenuItem[];

    //
    // True if clicking the menu leads to more options.
    //
    more?: boolean;

    //
    // Click handler for the menu item.
    //
    onClick?: () => void;
}

//
// Defines a breadcrumb item in the sidebar.
//
interface IBreadcrumb {
    //
    // The icon for the breadcrumb.
    //
    icon?: React.JSX.Element;

    //
    // The text for the breadcrumb.
    //
    text?: string;

    //
    // The menu to display when the breadcrumb is clicked.
    //
    menuPath: string[];
}

//
// Build the navigation menu from the gallery layout.
//
function buildNavMenu(layout: IGalleryLayout, scrollTo: (position: number) => void): IMenuItem[] {
    const menu: IMenuItem[] = [];

    const headingRows = layout.rows.filter(row => row.type === "heading");
    for (const row of headingRows) {
        let parentMenu = menu;
        for (let groupIndex = 0; groupIndex < row.group.length; groupIndex++) {
            let lastMenu = parentMenu.length > 0 ? parentMenu[parentMenu.length-1] : undefined;
            if (!lastMenu || lastMenu.text !== row.group[groupIndex]) {
                //
                // Create a new menu.
                //
                lastMenu = {
                    text: row.group[groupIndex],
                    children: [],
                };
                if (groupIndex === row.group.length-1) {
                    lastMenu.onClick = () => {
                        //
                        // Scroll to the row.
                        //
                        scrollTo(row.offsetY);
                    };
                }
                parentMenu.push(lastMenu);
            }
            parentMenu = lastMenu.children!;
        }
    }

    return menu;
}

//
// Creates the full nav menu.
//
function makeFullMenu(navMenu: IMenuItem[], years: string[], locations: string[], search: (searchText: string) => void, setSortBy: (sortBy: string) => void, isLoading: boolean): IMenuItem[] {
    const topMenu = [
        {
            icon: <Map />,
            text: "Navigation",
            children: navMenu,
        },
        {
            icon: <Search />,
            text: "Search",
            children: [
                {
                    icon: <CalendarMonth />,
                    text: "Date",
                    children: [
                        {
                            icon: <DateRange />,
                            text: "A particular day",
                            more: true,
                        },
                        {
                            icon: <DateRange />,
                            text: "Date range",
                            more: true,
                        },
                        {
                            icon: <DateRange />,
                            text: "Undated",
                            more: true,
                        },
                        {
                            text: "Year",
                            children: years.map(year => {
                                return {
                                    text: year,
                                    onClick: () => {
                                        search(`.date=${year}`);
                                    },
                                };
                            }),
                        },
                    ],
                },
                {
                    icon: <Place />,
                    text: "Place",
                    children: locations.map(location => {
                        return {
                            text: location,
                            onClick: () => {
                                search(`.location=${location}`);
                            },
                        };
                    }),
                },
            ],
        },
        {
            icon: <Category />,
            text: "Sort",
            children: [
                {
                    icon: <CalendarMonth />,
                    text: "Date",
                    onClick: isLoading ? undefined : () => {
                        setSortBy("date");
                    },
                },
                {
                    icon: <Place />,
                    text: "Place",
                    onClick: isLoading ? undefined : () => {
                        setSortBy("location");
                    },
                },
            ],
        },
    ];
    return topMenu;
}

//
// Renders the right sidebar for the app.
//
export function RightSidebar({ sidebarOpen, setSidebarOpen }: IRightSidebarProps) {
    const { recentSearches, removeRecentSearch, savedSearches, saveSearch, unsaveSearch } = useSearch();
    const { dbs } = useApp();

    //
    // Drives the mobile layout of the menu: larger buttons, because every button here is a thumb
    // target rather than a mouse target.
    //
    const isMobile = useIsMobile();

    //
    // Sizing for the small buttons that hang off the end of a search row (save, remove). Small
    // buttons sit next to each other and are easy to mis-hit with a thumb, so on a mobile they
    // take the medium button size.
    //
    const endActionSize = isMobile ? "var(--button-height-md)" : "var(--button-height-sm)";
    const endActionSx = {
        minHeight: endActionSize,
        minWidth: endActionSize,
        "& .MuiSvgIcon-root": {
            fontSize: "var(--icon-lg)",
        },
    };
    const { databasePath, closeDatabase, downloadAssets } = useAssetDatabase();
    const { search, setSortBy, isLoading, onReset, onNewItems, selectedItems, clearMultiSelection, moveSelectedToDatabase, getItemById } = useGallery();
    const { scrollTo, layout } = useGalleryLayout();
    const { setDeleteConfirmationOpen } = useDeleteConfirmation();
    const { updateAssets } = useGallerySource();

    const [menuPath, setMenuPath] = useState<string[]>([]);
    const [breadcrumbs, setBreadCrumbs] = useState<IBreadcrumb[]>([]);

    const yearsSetRef = useRef<Set<number>>(new Set<number>());
    const locationsSetRef = useRef<Set<string>>(new Set<string>());
    const [years, setYears] = useState<string[]>([]);
    const [locations, setLocations] = useState<string[]>([]);

    //
    // Set to true to open the bulk set date dialog.
    //
    const [setDateDialogOpen, setSetDateDialogOpen] = useState<boolean>(false);

    //
    // Set to true to open the bulk set location dialog.
    //
    const [setLocationDialogOpen, setSetLocationDialogOpen] = useState<boolean>(false);

    useEffect(() => {
        const subscription = onReset.subscribe(() => {
            yearsSetRef.current = new Set<number>();
            locationsSetRef.current = new Set<string>();
            setYears([]);
            setLocations([]);
        });
        return () => {
            subscription.unsubscribe();
        };
    }, []);

    useEffect(() => {
        const subscription = onNewItems.subscribe(newItems => {
            for (const item of newItems) {
                yearsSetRef.current.add(dayjs(item.fileDate).year());
                if (item.photoDate) {
                    yearsSetRef.current.add(dayjs(item.photoDate).year());
                }
                yearsSetRef.current.add(dayjs(item.uploadDate).year());

                if (item.location) {
                    const parts = item.location.split(",").map(part => part.trim());
                    if (parts.length > 0) {
                        locationsSetRef.current.add(parts[parts.length - 1]);
                        if (parts.length > 1) {
                            locationsSetRef.current.add(parts[parts.length - 2]);
                        }
                    }
                }
            }
            setYears(
                Array.from(yearsSetRef.current)
                    .sort((a, b) => b - a)
                    .map(year => year.toString())
            );
            setLocations(Array.from(locationsSetRef.current).sort());
        });
        return () => {
            subscription.unsubscribe();
        };
    }, []);

    const navMenu = layout ? buildNavMenu(layout, position => {
        scrollTo(position);
        setSidebarOpen(false);
    }) : [];
    const fullMenu = makeFullMenu(
        navMenu,
        years,
        locations,
        (searchText) => {
            search(searchText);
            setSidebarOpen(false);
        },
        (sortBy) => {
            setSortBy(sortBy);
            setSidebarOpen(false);
        },
        isLoading
    );

    let curMenu = fullMenu;

    for (const menuName of menuPath) {
        const menu = curMenu.find(menu => menu.text === menuName);
        if (menu) {
            curMenu = menu.children || [];
        }
        else {
            break;
        }
    }

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
        await downloadAssets(assets);
    }

    //
    // Closes the current database.
    //
    async function onCloseDatabase(): Promise<void> {
        clearMultiSelection();
        await closeDatabase();
    }

    return (
        <>
            {/* Fills the drawer rather than forcing a full viewport height. The header stays put,
                the sections (selection, searches, content) scroll when they run past the bottom
                and Close database stays pinned under them, so every section can be reached on a
                mobile. */}
            <div className="flex flex-col h-full">
                <div
                    className="flex flex-row items-center"
                    style={{
                        gap: "var(--space-3)",
                        padding: "var(--space-3) var(--space-3) var(--space-2) var(--space-4)",
                    }}
                    >
                    <h2
                        className="flex-1"
                        style={{
                            fontFamily: "var(--font-heading)",
                            fontSize: "var(--text-lg)",
                            fontWeight: "var(--weight-bold)",
                        }}
                        >
                        Menu
                    </h2>
                    <IconButton
                        title="Close menu"
                        aria-label="Close menu"
                        onClick={() => setSidebarOpen(!sidebarOpen)}
                        sx={{
                            minWidth: isMobile ? "var(--button-height-lg)" : undefined,
                            minHeight: isMobile ? "var(--button-height-lg)" : undefined,
                        }}
                        >
                        <ArrowForward
                            sx={{
                                fontSize: "var(--icon-lg)",
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
                    {databasePath && selectedItemsCount > 0 &&
                        <div data-id="right-sidebar-selection-section" className="flex flex-col">
                            <CollapsibleSection configKey="right-sidebar-collapsed-selection" label="Selection">
                                <List>
                                    <ListItem
                                        disablePadding
                                        data-id="download-selected-button"
                                        onClick={async () => {
                                            setSidebarOpen(false);
                                            await onDownloadSelected();
                                        }}
                                        >
                                        <ListItemButton>
                                            <ListItemIcon><Download /></ListItemIcon>
                                            <ListItemText>Download {selectedItemsCount} assets</ListItemText>
                                        </ListItemButton>
                                    </ListItem>
                                    <ListItem
                                        disablePadding
                                        onClick={() => {
                                            setSidebarOpen(false);
                                            setSetDateDialogOpen(true);
                                        }}
                                        >
                                        <ListItemButton>
                                            <ListItemIcon><CalendarMonth /></ListItemIcon>
                                            <ListItemText>Set date for {selectedItemsCount} assets</ListItemText>
                                        </ListItemButton>
                                    </ListItem>
                                    <ListItem
                                        disablePadding
                                        onClick={() => {
                                            setSidebarOpen(false);
                                            setSetLocationDialogOpen(true);
                                        }}
                                        >
                                        <ListItemButton>
                                            <ListItemIcon>
                                                <i
                                                    className="fa-regular fa-map"
                                                    style={{
                                                        width: "var(--icon-lg)",
                                                        textAlign: "center",
                                                    }}
                                                    />
                                            </ListItemIcon>
                                            <ListItemText>Set location for {selectedItemsCount} assets</ListItemText>
                                        </ListItemButton>
                                    </ListItem>
                                    {dbs.map(dbEntry => {
                                        if (dbEntry.path === databasePath) {
                                            return null;
                                        }
                                        return (
                                            <ListItem
                                                disablePadding
                                                key={dbEntry.name}
                                                data-id={`move-to-database-${dbEntry.name}`}
                                                onClick={() => {
                                                    moveSelectedToDatabase(dbEntry.path);
                                                    setSidebarOpen(false);
                                                }}
                                                >
                                                <ListItemButton>
                                                    <ListItemText>Move to {dbEntry.name}</ListItemText>
                                                </ListItemButton>
                                            </ListItem>
                                        );
                                    })}
                                    <li
                                        className="flex justify-end"
                                        style={{
                                            marginTop: "var(--space-2)",
                                            padding: "var(--space-3) var(--space-2) var(--space-1)",
                                            borderTop: "1px solid var(--color-border)",
                                        }}
                                        >
                                        <Button
                                            variant="outlined"
                                            color="error"
                                            size="small"
                                            startIcon={<Delete />}
                                            onClick={() => {
                                                setSidebarOpen(false);
                                                setDeleteConfirmationOpen(true);
                                            }}
                                            >
                                            Delete {selectedItemsCount} assets
                                        </Button>
                                    </li>
                                </List>
                            </CollapsibleSection>
                        </div>
                    }

                    <div className="flex flex-col">
                        <CollapsibleSection configKey="right-sidebar-collapsed-quickSearches" label="Quick Searches">
                            <List>
                                <ListItem
                                    disablePadding
                                    onClick={() => {
                                        search(".labels=starred");
                                        setSidebarOpen(false);
                                    }}
                                >
                                    <ListItemButton>
                                        <ListItemIcon><Star /></ListItemIcon>
                                        <ListItemText>Starred</ListItemText>
                                    </ListItemButton>
                                </ListItem>

                                <ListItem
                                    disablePadding
                                    onClick={() => {
                                        search(".labels=flagged");
                                        setSidebarOpen(false);
                                    }}
                                >
                                    <ListItemButton>
                                        <ListItemIcon><Flag /></ListItemIcon>
                                        <ListItemText>Flagged</ListItemText>
                                    </ListItemButton>
                                </ListItem>
                            </List>
                        </CollapsibleSection>
                    </div>

                    {savedSearches.length > 0 &&
                        <div className="flex flex-col">
                            <CollapsibleSection configKey="sidebar-collapsed-savedSearches" label="Saved Searches">
                                <List>
                                    {savedSearches.map(savedSearch => (
                                        <ListItem
                                            disablePadding
                                            key={savedSearch}
                                            secondaryAction={
                                                <IconButton
                                                    size="small"
                                                    title="Remove saved search"
                                                    onClick={async (event) => {
                                                        event.stopPropagation();
                                                        await unsaveSearch(savedSearch);
                                                    }}
                                                    sx={endActionSx}
                                                >
                                                    <Star
                                                        sx={{
                                                            color: "var(--color-accent)",
                                                        }}
                                                        />
                                                </IconButton>
                                            }
                                            >
                                            <ListItemButton
                                                onClick={() => {
                                                    search(savedSearch);
                                                    setSidebarOpen(false);
                                                }}
                                                >
                                                <ListItemIcon><StarBorder /></ListItemIcon>
                                                <ListItemText>{savedSearch}</ListItemText>
                                            </ListItemButton>
                                        </ListItem>
                                    ))}
                                </List>
                            </CollapsibleSection>
                        </div>
                    }

                    {recentSearches.length > 0 &&
                        <div className="flex flex-col">
                            <CollapsibleSection configKey="right-sidebar-collapsed-recentSearches" label="Recent Searches">
                                <List>
                                    {recentSearches.map(recentSearch => (
                                        <ListItem
                                            disablePadding
                                            key={recentSearch}
                                            secondaryAction={
                                                <>
                                                    <IconButton
                                                        size="small"
                                                        title={savedSearches.includes(recentSearch) ? "Unsave search" : "Save search"}
                                                        onClick={async (event) => {
                                                            event.stopPropagation();
                                                            if (savedSearches.includes(recentSearch)) {
                                                                await unsaveSearch(recentSearch);
                                                            }
                                                            else {
                                                                await saveSearch(recentSearch);
                                                            }
                                                        }}
                                                        sx={endActionSx}
                                                    >
                                                        {savedSearches.includes(recentSearch)
                                                            ? <Star />
                                                            : <StarBorder />
                                                        }
                                                    </IconButton>
                                                    <IconButton
                                                        size="small"
                                                        title="Remove from recent searches"
                                                        onClick={async (event) => {
                                                            event.stopPropagation();
                                                            await removeRecentSearch(recentSearch);
                                                        }}
                                                        sx={endActionSx}
                                                    >
                                                        <Delete />
                                                    </IconButton>
                                                </>
                                            }
                                            >
                                            <ListItemButton
                                                onClick={() => {
                                                    search(recentSearch);
                                                    setSidebarOpen(false);
                                                }}
                                                >
                                                <ListItemIcon><History /></ListItemIcon>
                                                <ListItemText>{recentSearch}</ListItemText>
                                            </ListItemButton>
                                        </ListItem>
                                    ))}
                                </List>
                            </CollapsibleSection>
                        </div>
                    }

                    <div className="flex flex-col">
                        <CollapsibleSection configKey="right-sidebar-collapsed-content" label="Content">
                            <>
                                {breadcrumbs.length > 0 &&
                                    <Breadcrumbs
                                        separator={<KeyboardArrowRight />}
                                        sx={{
                                            padding: "var(--space-1) var(--space-3)",
                                            color: "var(--color-text-muted)",
                                            "& .MuiTypography-root": {
                                                fontSize: "var(--text-sm)",
                                            },
                                            "& .MuiSvgIcon-root": {
                                                fontSize: "var(--icon-lg)",
                                            },
                                        }}
                                    >
                                        <Link
                                            component="button"
                                            onClick={() => {
                                                setMenuPath([]);
                                                setBreadCrumbs([]);
                                            }}
                                        >
                                            <Home />
                                        </Link>

                                        {breadcrumbs.length > 2 &&
                                            <Typography variant="caption">•••</Typography>
                                        }

                                        {breadcrumbs.length > 1 &&
                                            <Link
                                                component="button"
                                                sx={{
                                                    display: "inline-flex",
                                                    alignItems: "center",
                                                }}
                                                onClick={() => {
                                                    setMenuPath(breadcrumbs[breadcrumbs.length - 1].menuPath);
                                                    setBreadCrumbs(breadcrumbs.slice(0, breadcrumbs.length - 1));
                                                }}
                                            >
                                                {breadcrumbs[breadcrumbs.length - 2].icon}
                                                {breadcrumbs[breadcrumbs.length - 2].text &&
                                                    <Typography>
                                                        {breadcrumbs[breadcrumbs.length - 2].text}
                                                    </Typography>
                                                }
                                            </Link>
                                        }

                                        {breadcrumbs[breadcrumbs.length - 1].icon}

                                        {breadcrumbs[breadcrumbs.length - 1].text &&
                                            <Typography>
                                                {breadcrumbs[breadcrumbs.length - 1].text}
                                            </Typography>
                                        }
                                    </Breadcrumbs>
                                }

                                <List>
                                    {curMenu.map((menuItem, index) => {
                                        return (
                                            <ListItem
                                                disablePadding
                                                key={`${index}-${menuItem.text}`}
                                                onClick={() => {
                                                    if (menuItem.children && menuItem.children.length > 0) {
                                                        setBreadCrumbs([...breadcrumbs, {
                                                            text: menuItem.text,
                                                            menuPath,
                                                        }]);
                                                        setMenuPath([...menuPath, menuItem.text]);
                                                    }

                                                    if (menuItem.onClick) {
                                                        menuItem.onClick();
                                                    }
                                                }}
                                            >
                                                <ListItemButton>
                                                    <ListItemIcon>{menuItem.icon}</ListItemIcon>
                                                    <ListItemText>{menuItem.text}</ListItemText>
                                                    {menuItem.children && menuItem.children.length > 0 &&
                                                        <KeyboardArrowRight />
                                                    }
                                                    {menuItem.more &&
                                                        <MoreHoriz />
                                                    }
                                                </ListItemButton>
                                            </ListItem>
                                        );
                                    })}
                                </List>
                            </>
                        </CollapsibleSection>
                    </div>

                </Box>
                {databasePath &&
                    <div
                        style={{
                            padding: "var(--space-3) var(--space-4)",
                            borderTop: "1px solid var(--color-border)",
                            background: "var(--color-panel)",
                        }}
                        >
                        <Button
                            data-id="close-database-button"
                            variant="outlined"
                            fullWidth={true}
                            startIcon={<ExitToApp />}
                            onClick={async () => {
                                setSidebarOpen(false);
                                await onCloseDatabase();
                            }}
                            >
                            Close database
                        </Button>
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
        </>
    );
}
