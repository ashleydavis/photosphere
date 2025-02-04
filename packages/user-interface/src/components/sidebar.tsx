import Typography from '@mui/joy/Typography/Typography';
import React, { useEffect, useState } from 'react';
import { NavLink } from 'react-router-dom';
import { useApp } from '../context/app-context';
import { useAssetDatabase } from '../context/asset-database-source';
import { useTheme } from '@mui/joy/styles/ThemeProvider';
import List from '@mui/joy/List/List';
import ListItem from '@mui/joy/ListItem/ListItem';
import ListItemDecorator from '@mui/joy/ListItemDecorator/ListItemDecorator';
import { Event, List as ListIcon, CalendarMonth, Category, Cloud, Computer, Folder, FolderOpen, History, Home, KeyboardArrowRight, Label, Map, MoreHoriz, Navigation, People, Place, Search, Star, Upload, VerticalAlignBottom, VerticalAlignTop, DateRange } from '@mui/icons-material';
import ListItemContent from '@mui/joy/ListItemContent/ListItemContent';
import ListItemButton from '@mui/joy/ListItemButton/ListItemButton';
import Breadcrumbs from '@mui/joy/Breadcrumbs/Breadcrumbs';
import Link from '@mui/joy/Link/Link';
import Divider from '@mui/joy/Divider/Divider';
import { useGalleryLayout } from '../context/gallery-layout-context';
import { IGalleryLayout } from '../lib/create-layout';
import { useGallery } from '../context/gallery-context';
import Slider from '@mui/joy/Slider/Slider';
import Stack from '@mui/joy/Stack/Stack';
import dayjs from 'dayjs';

export interface ISidebarProps {
    //
    // True if the sidebar is open.
    //
    sidebarOpen: boolean;

    //
    // Sets the sidebar open or close.
    //
    setSidebarOpen: (open: boolean) => void;

    //
    // Opens the search input.
    //
    onOpenSearch: () => void;

    //
    // The "computer page" which is only displayed in the Electron or mobile version.
    //
    computerPage?: JSX.Element;

    //
    // Navigates to a set.
    //
    navigateToSet: (page: string, setId: string) => void;
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
            let lastMenu = parentMenu.length > 0 ? parentMenu[parentMenu.length-1] : undefined
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
// Determine the set of unique years of photos.
//
function determineYears(layout: IGalleryLayout): string[] {
    const years = new Set<number>();
    for (const row of layout.rows) {
        for (const item of row.items) {

            const fileYear = dayjs(item.fileDate).year();
            years.add(fileYear);
            
            if (item.photoDate) {
                const photoYear = dayjs(item.photoDate).year();
                years.add(photoYear);
            }

            const uploadYear = dayjs(item.uploadDate).year();
            years.add(uploadYear);
        }
    }

    return Array.from(years)
        .sort((a, b) => b - a)
        .map(year => year.toString());
}

//
// Determines the unique locations in the layout.
//
function determineLocations(layout: IGalleryLayout): string[] {
    const locations = new Set<string>();
    for (const row of layout.rows) {
        for (const item of row.items) {
            if (item.location) {
                const parts = item.location.split(",").map(part => part.trim());
                if (parts.length > 0) {
                    locations.add(parts[parts.length-1]);

                    if (parts.length > 1) {
                        locations.add(parts[parts.length-2]);
                    }
                }
            }
        }
    }

    return Array.from(locations)
        .sort();
}

//
// Creates the full nav meu.
//
function makeFullMenu(navMenu: IMenuItem[], years: string[], locations: string[], search: (searchText: string) => void, setSortBy: (sortBy: string) => void) : IMenuItem[] {
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
                //todo:
                // {
                //     icon: <History />,
                //     text: "Recent",
                // },
                // {
                //     icon: <Star />,
                //     text: "Starred",
                // },
                {
                    icon: <CalendarMonth />, //todo: How do I generate this?
                    text: "Date",
                    children: [
                        {
                            icon: <DateRange />, //todo: Date picker?
                            text: "A particular day",
                            more: true,
                        },
                        {
                            icon: <DateRange />, //todo: //todo: Date picker?
                            text: "Date range",
                            more: true,
                        },
                        {
                            icon: <DateRange />, //todo: 
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
                //todo:
                // {
                //     icon: <People />,
                //     text: "People",
                //     children: [
                //         {
                //             text: "Ashley",
                //         },
                //         {
                //             text: "Antonella",
                //         },
                //         {
                //             text: "Lucia",
                //         },
                //         {
                //             text: "Lucio",
                //         },
                //     ],
                // },
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
                // {
                //     icon: <Event />,
                //     text: "Event",
                //     children: [
                //         {
                //             text: "Birthday",
                //             onClick: () => {
                //                 search(".event=contains(birthday)");
                //             },
                //         },
                //         {
                //             text: "Wedding",
                //             onClick: () => {
                //                 search(".event=contains(wedding)");
                //             },
                //         },
                //         {
                //             text: "Graduation",
                //             onClick: () => {
                //                 search(".event=contains(graduation)");
                //             },
                //         },
                //         {
                //             text: "Party",
                //             onClick: () => {
                //                 search(".event=contains(party)");
                //             },
                //         },
                //         {
                //             text: "Edit", //todo:
                //             more: true,
                //         },
                //     ],                        
                // },
                // {
                //     icon: <Label />,
                //     text: "Label",
                //     children: [
                //         {
                //             text: "Vacation",
                //             onClick: () => {
                //                 search(".labels=has(vacation)");
                //             },
                //         },
                //         {
                //             text: "Family",
                //             onClick: () => {
                //                 search(".labels=has(family)");
                //             },
                //         },
                //         {
                //             text: "Work",
                //             onClick: () => {
                //                 search(".labels=has(work)");
                //             },
                //         },
                //         {
                //             text: "Friends",
                //             onClick: () => {
                //                 search(".labels=has(friends)");
                //             },
                //         },
                //         {
                //             text: "Edit", //todo:
                //             more: true,
                //         },
                //     ],
                // },
                //todo:
                // {
                //     icon: <ListIcon />,
                //     text: "Property",
                //     more: true,
                // },
            ],
        },
        {
            icon: <Category />,
            text: "Sort",
            children: [
                {
                    icon: <CalendarMonth />,
                    text: "Date",
                    onClick: () => {
                        setSortBy("date");
                    },
                },
                //todo:
                // {
                //     icon: <People />,
                //     text: "People",
                // },
                {
                    icon: <Place />,
                    text: "Place",
                    onClick: () => {
                        setSortBy("location");
                    },
                },
                //todo:
                // {
                //     icon: <Event />,
                //     text: "Event",
                // },
                // {
                //     icon: <Label />,
                //     text: "Label",
                // },
                // {
                //     icon: <ListIcon />,
                //     text: "Property",
                //     more: true,
                // },
            ],
        },
    ];
    return topMenu;
}

//
// Renders the sidebar for the app.
//
export function Sidebar({ sidebarOpen, setSidebarOpen, onOpenSearch, computerPage, navigateToSet }: ISidebarProps) {

    const { user } = useApp();
    const theme = useTheme();
    const { setId } = useAssetDatabase();
    const { search, setSortBy } = useGallery();
    const { scrollTo, layout, targetRowHeight, setTargetRowHeight } = useGalleryLayout();

    const [menuPath, setMenuPath] = useState<string[]>([]);
    const [breadcrumbs, setBreadCrumbs] = useState<IBreadcrumb[]>([]);

    const navMenu = layout ? buildNavMenu(layout, position => {
        scrollTo(position);
        setSidebarOpen(false);
    }) : [];
    const years = layout ? determineYears(layout) : [];
    const locations = layout ? determineLocations(layout) : [];
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
        }
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

    return (
        <div
            className="flex flex-col"
            style={{
                paddingLeft: "15px",
                backgroundColor: theme.palette.background.body,
                color: theme.palette.text.primary,
            }}
            >
            <div className="flex flex-row items-center mt-4">
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

            <List>
                <ListItem
                    onClick={() => {
                        setSidebarOpen(false);
                        setTimeout(() => { // Delay the opening of the search input allows it auto focus.
                            onOpenSearch();
                        }, 10);
                    }}
                    >
                    <ListItemButton>
                        <ListItemDecorator><Search /></ListItemDecorator>
                        <ListItemContent>Search</ListItemContent>
                    </ListItemButton>
                </ListItem>

                <NavLink
                    to="/cloud"
                    onClick={() => setSidebarOpen(false)}
                    >
                    <ListItem>
                        <ListItemButton>
                            <ListItemDecorator><Cloud /></ListItemDecorator>
                            <ListItemContent>Cloud</ListItemContent>
                        </ListItemButton>
                    </ListItem>
                </NavLink>

                {computerPage
                    && <NavLink
                        to="/computer"
                        onClick={() => setSidebarOpen(false)}
                        >
                        <ListItem>                        
                            <ListItemButton>
                                <ListItemDecorator><Computer /></ListItemDecorator>
                                <ListItemContent>Computer</ListItemContent>
                            </ListItemButton>
                        </ListItem>
                    </NavLink>
                }

                <NavLink
                    to="/upload"
                    onClick={() => setSidebarOpen(false)}
                    >
                    <ListItem>
                            <ListItemButton>
                                <ListItemDecorator><Upload /></ListItemDecorator>
                                <ListItemContent>Upload</ListItemContent>
                            </ListItemButton>
                    </ListItem>
                </NavLink>
            </List>

            <Divider />

            <Typography
                level="body-xs"
                sx={{ textTransform: 'uppercase', fontWeight: 'lg', mt: 2 }}
                >
                Sets
            </Typography>

            <List>
                {user?.sets.map(set => {
                    return (
                        <ListItem
                            key={set.id}
                            onClick={() => {
                                setSidebarOpen(false);
                                navigateToSet("cloud", set.id)
                            }}
                            >
                            <ListItemButton>
                                <ListItemDecorator>
                                    {set.id === setId
                                        ? <FolderOpen />
                                        : <Folder />
                                    }
                                </ListItemDecorator>
                                <ListItemContent>{set.name}</ListItemContent>
                            </ListItemButton>
                        </ListItem>
                    );
                })}
            </List>

            <Divider />

            <Typography
                level="body-xs"
                sx={{ textTransform: 'uppercase', fontWeight: 'lg', mt: 2 }}
                >
                Content
            </Typography>

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
                                setMenuPath(breadcrumbs[breadcrumbs.length-2].menuPath);
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

            <Divider />

            <Typography
                level="body-xs"
                sx={{ textTransform: 'uppercase', fontWeight: 'lg', mt: 2 }}
                >
                Configuration
            </Typography>

           <Stack
                sx={{ mt: 2, mr: 2 }}
                >
                <Typography level="body-xs">Row Height</Typography>                
                <Slider 
                    min={50}
                    max={500}
                    value={targetRowHeight}
                    onChange={(e, value) => setTargetRowHeight(value as number)}
                    />
            </Stack>

      </div>
    );

}