import Box from '@mui/joy/Box/Box';
import ModalClose from '@mui/joy/ModalClose/ModalClose';
import Typography from '@mui/joy/Typography/Typography';
import React from 'react';
import { NavLink } from 'react-router-dom';
import { useApp } from '../context/app-context';
import classNames from 'classnames';
import { useAssetDatabase } from '../context/asset-database-source';
import { useTheme } from '@mui/joy/styles/ThemeProvider';
import List from '@mui/joy/List/List';
import ListItem from '@mui/joy/ListItem/ListItem';
import ListItemDecorator from '@mui/joy/ListItemDecorator/ListItemDecorator';
import { CalendarMonth, Cloud, Computer, Folder, FolderOpen, History, Home, KeyboardArrowRight, Label, Label, MoreHoriz, People, Place, Search, Star, Upload, VerticalAlignBottom, VerticalAlignTop } from '@mui/icons-material';
import ListItemContent from '@mui/joy/ListItemContent/ListItemContent';
import ListItemButton from '@mui/joy/ListItemButton/ListItemButton';

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
// Renders the sidebar for the app.
//
export function Sidebar({ sidebarOpen, setSidebarOpen, onOpenSearch, computerPage, navigateToSet }: ISidebarProps) {

    const { user } = useApp();
    const theme = useTheme();
    const { setId } = useAssetDatabase();

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

            <Typography
                level="body-xs"
                sx={{ textTransform: 'uppercase', fontWeight: 'lg', mt: 2 }}
                >
                Navigation
            </Typography>

            <List>
                <ListItem>
                    <ListItemButton>
                        <ListItemDecorator><VerticalAlignTop /></ListItemDecorator>
                        <ListItemContent>Start</ListItemContent>
                    </ListItemButton>
                </ListItem>

                <ListItem>
                    <ListItemButton>
                        <ListItemDecorator><VerticalAlignBottom /></ListItemDecorator>
                        <ListItemContent>End</ListItemContent>
                    </ListItemButton>
                </ListItem>

                <ListItem>
                    <ListItemButton>
                        <ListItemDecorator><CalendarMonth /></ListItemDecorator>
                        <ListItemContent>Date</ListItemContent>
                        <KeyboardArrowRight />
                    </ListItemButton>
                </ListItem>

                <ListItem>
                    <ListItemButton>
                        <ListItemDecorator><Place /></ListItemDecorator>
                        <ListItemContent>Place</ListItemContent>
                        <KeyboardArrowRight />
                    </ListItemButton>
                </ListItem>
            </List>

            <Typography
                level="body-xs"
                sx={{ textTransform: 'uppercase', fontWeight: 'lg', mt: 2, mb: 1 }}
                >                
                Searches
            </Typography>

            <List>
                <ListItem>
                    <ListItemButton>
                        <ListItemDecorator><History /></ListItemDecorator>
                        <ListItemContent>Recent</ListItemContent>
                        <KeyboardArrowRight />
                    </ListItemButton>
                </ListItem>

                <ListItem>
                    <ListItemButton>
                        <ListItemDecorator><Star /></ListItemDecorator>
                        <ListItemContent>Starred</ListItemContent>
                    </ListItemButton>
                </ListItem>

                <ListItem>
                    <ListItemButton>
                        <ListItemDecorator><CalendarMonth /></ListItemDecorator>
                        <ListItemContent>Date</ListItemContent>
                        <KeyboardArrowRight />
                    </ListItemButton>
                </ListItem>

                <ListItem>
                    <ListItemButton>
                        <ListItemDecorator><People /></ListItemDecorator>
                        <ListItemContent>People</ListItemContent>
                        <KeyboardArrowRight />
                    </ListItemButton>
                </ListItem>

                <ListItem>
                    <ListItemButton>
                        <ListItemDecorator><Place /></ListItemDecorator>
                        <ListItemContent>Place</ListItemContent>
                        <KeyboardArrowRight />
                    </ListItemButton>
                </ListItem>

                <ListItem>
                    <ListItemButton>
                        <ListItemDecorator><Label /></ListItemDecorator>
                        <ListItemContent>Label</ListItemContent>
                        <KeyboardArrowRight />
                    </ListItemButton>
                </ListItem>

                {/* More examples under this one. */}
                <ListItem>
                    <ListItemButton>
                        <ListItemDecorator><MoreHoriz /></ListItemDecorator>
                        <ListItemContent>More</ListItemContent>
                        <KeyboardArrowRight />
                    </ListItemButton>
                </ListItem>
            </List>

            <Typography
                level="body-xs"
                sx={{ textTransform: 'uppercase', fontWeight: 'lg', mt: 2, mb: 1 }}
                >
                Group by
            </Typography>

            <List>
                <ListItem>
                    <ListItemButton>
                        <ListItemDecorator><People /></ListItemDecorator>
                        <ListItemContent>People</ListItemContent>
                        <KeyboardArrowRight />
                    </ListItemButton>
                </ListItem>

                <ListItem>
                    <ListItemButton>
                        <ListItemDecorator><CalendarMonth /></ListItemDecorator>
                        <ListItemContent>Date</ListItemContent>
                        <KeyboardArrowRight />
                    </ListItemButton>
                </ListItem>

                <ListItem>
                    <ListItemButton>
                        <ListItemDecorator><Place /></ListItemDecorator>
                        <ListItemContent>Place</ListItemContent>
                        <KeyboardArrowRight />
                    </ListItemButton>
                </ListItem>

                <ListItem>
                    <ListItemButton>
                        <ListItemDecorator><Label /></ListItemDecorator>
                        <ListItemContent>Label</ListItemContent>
                        <KeyboardArrowRight />
                    </ListItemButton>
                </ListItem>
            </List>
        </div>
    );

}