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
    navigateToSet: (setId: string) => void;
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
    icon?: JSX.Element;
    text?: string;
    menu: IMenuItem[];
}

//
// Renders the sidebar for the app.
//
export function Sidebar({ sidebarOpen, setSidebarOpen, onOpenSearch, computerPage, navigateToSet }: ISidebarProps) {

    const { user } = useApp();
    const theme = useTheme();
    const { setId } = useAssetDatabase();
    const { setScrollTop, layout } = useGalleryLayout();

    const [topMenu, setTopMenu] = useState<IMenuItem[]>([]);
    const [curMenu, setCurMenu] = useState<IMenuItem[]>([]);
    const [breadcrumbs, setBreadCrumbs] = useState<IBreadcrumb[]>([]);

    //
    // Build the navigation menu from the gallery layout.
    //
    function buildNavMenu(layout: IGalleryLayout): IMenuItem[] {
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
                            setScrollTop(row.offsetY);
                            setSidebarOpen(false);
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
    // Resets the sidebar menu to the top menu whenever the layout changes.
    //
    useEffect(() => {
        if (!layout) {
            return;
        }

        const navMenu = buildNavMenu(layout);

        const topMenu = [
            {
                icon: <Map />,
                text: "Navigation",
                children: [
                    {
                        icon: <VerticalAlignTop />,
                        text: "Start",
                    },
                    {
                        icon: <VerticalAlignBottom />,
                        text: "End",
                    },
                    {
                        icon: <CalendarMonth />,
                        text: "Date",
                        children: navMenu,
                    },                
                ],
            },
            {
                icon: <Search />,
                text: "Search",
                children: [
                    {
                        icon: <History />,
                        text: "Recent",
                    },
                    {
                        icon: <Star />,
                        text: "Starred",
                    },
                    {
                        icon: <CalendarMonth />,
                        text: "Date",
                        children: [
                            {
                                icon: <DateRange />,
                                text: "Date range",
                                more: true,
                            },
                            {
                                icon: <DateRange />,
                                text: "No date",
                                more: true,
                            },
                            {
                                text: "Year",
                                children: [
                                    {
                                        text: "2024",
                                    },
                                    {
                                        text: "2023",
                                    },
                                    {
                                        text: "2022",
                                    },
                                    {
                                        text: "2020",
                                    },
                                    {
                                        text: "2021",
                                    },
                                ],
                            },
                            {
                                text: "Month",
                                children: [
                                    {
                                        text: "December",
                                    },
                                    {
                                        text: "November",
                                    },
                                    {
                                        text: "October",
                                    },
                                    {
                                        text: "September",
                                    },
                                    {
                                        text: "August",
                                    },
                                    {
                                        text: "July",
                                    },
                                    {
                                        text: "June",
                                    },
                                    {
                                        text: "May",
                                    },
                                    {
                                        text: "April",
                                    },
                                    {
                                        text: "March",
                                    },
                                    {
                                        text: "February",
                                    },
                                    {
                                        text: "January",
                                    },
                                ],                                
                            },
                        ],
                    },
                    {
                        icon: <People />,
                        text: "People",
                        children: [
                            {
                                text: "Ashley",
                            },
                            {
                                text: "Antonella",
                            },
                            {
                                text: "Lucia",
                            },
                            {
                                text: "Lucio",
                            },
                        ],
                    },
                    {
                        icon: <Place />,
                        text: "Place",
                        children: [
                            {
                                text: "No location",
                            },
                            {
                                text: "Australia",
                                children: [
                                    {
                                        text: "Sydney",
                                    },
                                    {
                                        text: "Melbourne",
                                    },
                                    {
                                        text: "Brisbane",
                                    },
                                    {
                                        text: "Perth",
                                    },
                                ],
                            },
                            {
                                text: "United Kingdom",
                                children: [
                                    {
                                        text: "London",
                                    },
                                    {
                                        text: "Manchester",
                                    },
                                    {
                                        text: "Birmingham",
                                    },
                                    {
                                        text: "Glasgow",
                                    },
                                ],
                            },
                            {
                                text: "Italy",
                                children: [
                                    {
                                        text: "Rome",
                                    },
                                    {
                                        text: "Abruzzo",
                                    },
                                    {
                                        text: "Naples",
                                    },
                                    {
                                        text: "Turin",
                                    },
                                ],
                            },
                        ],
                    },
                    {
                        icon: <Event />,
                        text: "Event",
                        children: [
                            {
                                text: "Birthday",
                            },
                            {
                                text: "Wedding",
                            },
                            {
                                text: "Graduation",
                            },
                            {
                                text: "Party",
                            },
                        ],
                    },
                    {
                        icon: <Label />,
                        text: "Label",
                        children: [
                            {
                                text: "Vacation",
                            },
                            {
                                text: "Family",
                            },
                            {
                                text: "Work",
                            },
                            {
                                text: "Friends",
                            },
                            {
                                text: "More",
                                more: true,
                            },
                        ],
                    },
                    {
                        icon: <ListIcon />,
                        text: "Property",
                        more: true,
                    },
                ],
            },
            {
                icon: <Category />,
                text: "Grouping",
                children: [
                    {
                        icon: <CalendarMonth />,
                        text: "Date",
                    },
                    {
                        icon: <People />,
                        text: "People",
                    },
                    {
                        icon: <Place />,
                        text: "Place",
                    },
                    {
                        icon: <Event />,
                        text: "Event",
                    },
                    {
                        icon: <Label />,
                        text: "Label",
                    },
                    {
                        icon: <ListIcon />,
                        text: "Property",
                        more: true,
                    },
                ],
            },
        ];
        setTopMenu(topMenu);
        setCurMenu(topMenu);
        setBreadCrumbs([]);
    }, [layout]);

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
                        onOpenSearch();
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
                                navigateToSet(set.id)
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
                            setCurMenu(topMenu);
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
                                setCurMenu(breadcrumbs[breadcrumbs.length-2].menu);
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
                            key={index}
                            onClick={() => {
                                if (menuItem.children && menuItem.children.length > 0) {
                                    setCurMenu(menuItem.children);
                                    setBreadCrumbs([...breadcrumbs, {
                                        text: menuItem.text,
                                        menu: menuItem.children,
                                    }]);
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
      </div>
    );

}