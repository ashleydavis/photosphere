import Box from '@mui/joy/Box/Box';
import ModalClose from '@mui/joy/ModalClose/ModalClose';
import Typography from '@mui/joy/Typography/Typography';
import React from 'react';
import { NavLink } from 'react-router-dom';
import { useApp } from '../context/app-context';
import classNames from 'classnames';
import { useAssetDatabase } from '../context/asset-database-source';
import { useTheme } from '@mui/joy';

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
    const {  setId } = useAssetDatabase();

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

            <button
                className="mt-4"
                onClick={onOpenSearch}
                >
                <div className="flex flex-row items-center pl-1">
                    <i className="w-12 text-center fa-solid fa-search"></i>
                    <div className="">Search</div>
                </div>
            </button>

            <h2 className="text-lg mt-8">
                Pages
            </h2>

            <NavLink to="/cloud">
                <div className="flex flex-row items-center pl-1 mt-2">
                    <i className="w-12 text-center fa-solid fa-cloud"></i>
                    <div className="">Cloud</div>
                </div>
            </NavLink>

            {computerPage
                && <NavLink to="/computer">
                    <div className="flex flex-row items-center pl-1 mt-2">
                        <i className="w-12 text-center fa-solid fa-computer"></i>
                        <div className="">Computer</div>
                    </div>
                </NavLink>
            }

            <NavLink to="/upload">
                <div className="flex flex-row items-center pl-1 mt-2">
                    <i className="w-12 text-center fa-solid fa-upload"></i>
                    <div className="">Upload</div>
                </div>
            </NavLink>

            {/* <button
                className="flex flex-row items-center pl-1 mt-8 cursor-pointer"
                onClick={event => notImplemented(event)}
                >
                <i className="w-12 text-center fa-regular fa-star"></i>
                <div className="">Favorites</div>
            </button>

            <button
                className="flex flex-row items-center pl-1 mt-2 cursor-pointer"
                onClick={event => notImplemented(event)}
                >
                <i className="w-12 text-center fa-regular fa-trash-can"></i>
                <div className="">Trash</div>
            </button> */}

            <div className="flex flex-col pl-1 mt-8 mb-8">
                <h2 className="text-lg">
                    Sets
                </h2>

                {user?.sets.map(set => {
                    return (
                        <button
                            key={set.id}
                            className="flex flex-row items-center cursor-pointer"
                            onClick={() => navigateToSet(set.id)}
                            >
                            <div className="flex flex-row items-center pl-1 mt-2">
                                <i className={classNames("w-12 text-center fa-solid fa-folder", {
                                    "fa-folder": set.id !== setId,
                                    "fa-folder-open": set.id === setId,
                                })}></i>
                                <div className="">{set.name}</div>
                            </div>
                        </button>
                    );
                })}
            </div>
        </div>
    );

}