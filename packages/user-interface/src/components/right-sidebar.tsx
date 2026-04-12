import Typography from '@mui/joy/Typography/Typography';
import React, { useEffect, useRef, useState } from 'react';
import { useApp } from '../context/app-context';
import { useAssetDatabase } from '../context/asset-database-source';
import { useTheme } from '@mui/joy/styles/ThemeProvider';
import List from '@mui/joy/List/List';
import ListItem from '@mui/joy/ListItem/ListItem';
import ListItemDecorator from '@mui/joy/ListItemDecorator/ListItemDecorator';
import { CalendarMonth, Category, DateRange, Delete, Event, ExitToApp, Flag, Home, KeyboardArrowRight, Label, Map, MoreHoriz, Navigation, People, Place, Search, Star, StarBorder, History } from '@mui/icons-material';
import { CollapsibleSection } from './collapsible-section';
import ListItemContent from '@mui/joy/ListItemContent/ListItemContent';
import ListItemButton from '@mui/joy/ListItemButton/ListItemButton';
import IconButton from '@mui/joy/IconButton/IconButton';
import Breadcrumbs from '@mui/joy/Breadcrumbs/Breadcrumbs';
import Link from '@mui/joy/Link/Link';
import Divider from '@mui/joy/Divider/Divider';
import { useGalleryLayout } from '../context/gallery-layout-context';
import { IGalleryLayout } from '../lib/create-layout';
import { useGallery } from '../context/gallery-context';
import { useSearch } from '../context/search-context';
import dayjs from 'dayjs';
import { useDeleteConfirmation } from '../context/delete-confirmation-context';
import { usePlatform } from '../context/platform-context';
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
    icon?: JSX.Element;

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
    icon?: JSX.Element;

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
    const { setOpenSearch, recentSearches, removeRecentSearch, savedSearches, saveSearch, unsaveSearch } = useSearch();
    const { dbs } = useApp();
    const theme = useTheme();
    const { databasePath, closeDatabase } = useAssetDatabase();
    const { search, setSortBy, isLoading, onReset, onNewItems, selectedItems, clearMultiSelection, moveSelectedToDatabase, getItemById } = useGallery();
    const { scrollTo, layout } = useGalleryLayout();
    const { setDeleteConfirmationOpen } = useDeleteConfirmation();
    const { downloadAssets } = usePlatform();
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
        await downloadAssets(assets, databasePath!);
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
            <div
                className="flex flex-col h-full"
                style={{
                    paddingLeft: "15px",
                    color: theme.palette.text.primary,
                }}
                >
                <div className="flex flex-row items-center mt-4">
                    <button
                        className="ml-3 text-xl"
                        onClick={() => setSidebarOpen(!sidebarOpen)}
                        >
                        <i className="fa-solid fa-arrow-right"></i>
                    </button>
                    <div className="flex-grow" />
                </div>

                {databasePath && selectedItemsCount > 0 &&
                    <>
                        <Divider />
                        <CollapsibleSection configKey="right-sidebar-collapsed-selection" label="Selection">
                            <List>
                                {dbs.map(dbPath => {
                                    if (dbPath === databasePath) {
                                        return null;
                                    }
                                    return (
                                        <ListItem
                                            key={dbPath}
                                            onClick={() => {
                                                moveSelectedToDatabase(dbPath);
                                                setSidebarOpen(false);
                                            }}
                                            >
                                            <ListItemButton>
                                                <ListItemContent>Move to {dbPath.split(/[\\/]/).filter(Boolean).pop() ?? dbPath}</ListItemContent>
                                            </ListItemButton>
                                        </ListItem>
                                    );
                                })}
                                <ListItem
                                    onClick={() => {
                                        setSidebarOpen(false);
                                        setDeleteConfirmationOpen(true);
                                    }}
                                    >
                                    <ListItemButton color="danger">
                                        <ListItemDecorator><Delete /></ListItemDecorator>
                                        <ListItemContent>Delete {selectedItemsCount} assets</ListItemContent>
                                    </ListItemButton>
                                </ListItem>
                                <ListItem
                                    onClick={async () => {
                                        setSidebarOpen(false);
                                        await onDownloadSelected();
                                    }}
                                    >
                                    <ListItemButton>
                                        <ListItemDecorator><Download /></ListItemDecorator>
                                        <ListItemContent>Download {selectedItemsCount} assets</ListItemContent>
                                    </ListItemButton>
                                </ListItem>
                                <ListItem
                                    onClick={() => {
                                        setSidebarOpen(false);
                                        setSetDateDialogOpen(true);
                                    }}
                                    >
                                    <ListItemButton>
                                        <ListItemDecorator><CalendarMonth /></ListItemDecorator>
                                        <ListItemContent>Set date for {selectedItemsCount} assets</ListItemContent>
                                    </ListItemButton>
                                </ListItem>
                                <ListItem
                                    onClick={() => {
                                        setSidebarOpen(false);
                                        setSetLocationDialogOpen(true);
                                    }}
                                    >
                                    <ListItemButton>
                                        <ListItemDecorator><i className="fa-regular fa-map" style={{ width: "24px", textAlign: "center" }} /></ListItemDecorator>
                                        <ListItemContent>Set location for {selectedItemsCount} assets</ListItemContent>
                                    </ListItemButton>
                                </ListItem>
                            </List>
                        </CollapsibleSection>
                    </>
                }

                <Divider />
                <CollapsibleSection configKey="right-sidebar-collapsed-quickSearches" label="Quick Searches">
                    <List>
                        <ListItem
                            onClick={() => {
                                search(".labels=starred");
                                setSidebarOpen(false);
                            }}
                            >
                            <ListItemButton>
                                <ListItemDecorator><Star /></ListItemDecorator>
                                <ListItemContent>Starred</ListItemContent>
                            </ListItemButton>
                        </ListItem>

                        <ListItem
                            onClick={() => {
                                search(".labels=flagged");
                                setSidebarOpen(false);
                            }}
                            >
                            <ListItemButton>
                                <ListItemDecorator><Flag /></ListItemDecorator>
                                <ListItemContent>Flagged</ListItemContent>
                            </ListItemButton>
                        </ListItem>
                    </List>
                </CollapsibleSection>

                {recentSearches.length > 0 &&
                    <>
                        <Divider />
                        <CollapsibleSection configKey="right-sidebar-collapsed-recentSearches" label="Recent Searches">
                            <List>
                                {recentSearches.map(recentSearch => (
                                    <ListItem
                                        key={recentSearch}
                                        endAction={
                                            <>
                                                <IconButton
                                                    size="sm"
                                                    variant="plain"
                                                    color="neutral"
                                                    title={savedSearches.includes(recentSearch) ? "Unsave search" : "Save search"}
                                                    onClick={async (e) => {
                                                        e.stopPropagation();
                                                        if (savedSearches.includes(recentSearch)) {
                                                            await unsaveSearch(recentSearch);
                                                        }
                                                        else {
                                                            await saveSearch(recentSearch);
                                                        }
                                                    }}
                                                    sx={{ minHeight: '32px', minWidth: '32px' }}
                                                >
                                                    {savedSearches.includes(recentSearch)
                                                        ? <Star fontSize="small" />
                                                        : <StarBorder fontSize="small" />
                                                    }
                                                </IconButton>
                                                <IconButton
                                                    size="sm"
                                                    variant="plain"
                                                    color="neutral"
                                                    onClick={async (e) => {
                                                        e.stopPropagation();
                                                        await removeRecentSearch(recentSearch);
                                                    }}
                                                    sx={{ minHeight: '32px', minWidth: '32px' }}
                                                >
                                                    <Delete fontSize="small" />
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
                                            <ListItemDecorator><History /></ListItemDecorator>
                                            <ListItemContent>{recentSearch}</ListItemContent>
                                        </ListItemButton>
                                    </ListItem>
                                ))}
                            </List>
                        </CollapsibleSection>
                    </>
                }

                <Divider />
                <CollapsibleSection configKey="right-sidebar-collapsed-content" label="Content">
                    <>
                        {breadcrumbs.length > 0 &&
                            <Breadcrumbs
                                separator={<KeyboardArrowRight />}
                                >
                                <Link
                                    onClick={() => {
                                        setMenuPath([]);
                                        setBreadCrumbs([]);
                                    }}
                                    >
                                    <Home />
                                </Link>

                                {breadcrumbs.length > 2 &&
                                    <Typography level="body-xs">•••</Typography>
                                }

                                {breadcrumbs.length > 1 &&
                                    <Link
                                        onClick={() => {
                                            setMenuPath(breadcrumbs[breadcrumbs.length-1].menuPath);
                                            setBreadCrumbs(breadcrumbs.slice(0, breadcrumbs.length-1));
                                        }}
                                        >
                                        {breadcrumbs[breadcrumbs.length-2].icon}
                                        {breadcrumbs[breadcrumbs.length-2].text &&
                                            <Typography>
                                                {breadcrumbs[breadcrumbs.length-2].text}
                                            </Typography>
                                        }
                                    </Link>
                                }

                                {breadcrumbs[breadcrumbs.length-1].icon}

                                {breadcrumbs[breadcrumbs.length-1].text &&
                                    <Typography>
                                        {breadcrumbs[breadcrumbs.length-1].text}
                                    </Typography>
                                }
                            </Breadcrumbs>
                        }

                        <List>
                            {curMenu.map((menuItem, index) => {
                                return (
                                    <ListItem
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
                                            <ListItemDecorator>{menuItem.icon}</ListItemDecorator>
                                            <ListItemContent>{menuItem.text}</ListItemContent>
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

                <div className="flex-grow" />
                {databasePath &&
                    <>
                        <Divider />
                        <List>
                            <ListItem
                                onClick={async () => {
                                    setSidebarOpen(false);
                                    await onCloseDatabase();
                                }}
                                >
                                <ListItemButton>
                                    <ListItemDecorator><ExitToApp /></ListItemDecorator>
                                    <ListItemContent>Close database</ListItemContent>
                                </ListItemButton>
                            </ListItem>
                        </List>
                    </>
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
