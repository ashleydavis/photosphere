import React, { useState } from "react";
import { NavLink } from "react-router-dom";
import { useApi } from "../context/api-context";
import { AssetInfo } from "./asset-info";
import { useGalleryItem } from "../context/gallery-item-context";

export interface IAssetViewProps { 

    //
    // Set to true to open the asset view modal.
    //
    open: boolean;

    //
    // Event raised when the model is closed.
    //
    onClose: () => void;
    

    //
    // Event raised to move to the next asset in the gallery.
    //
    onNext: () => void;

    //
    // Event raised to move to the previous asset in the gallery.
    //
    onPrev: () => void;
}

//
// Shows info for a particular asset.
//
export function AssetView({ open, onClose, onNext, onPrev }: IAssetViewProps) {

    //
    // Interface to the gallery item.
    //
    const { asset } = useGalleryItem();

    //
    // Interface to the backend.
    //
    const api = useApi();

    // 
    // Set to true to open the info modal.
    //
    const [ openInfo, setOpenInfo ] = useState<boolean>(false);

    function notImplemented(event: any) {
        alert("This is a not implemented yet.");

        event.preventDefault();
        event.stopPropagation();
    }

    return (
        <div className={"photo flex flex-col " + (open ? "open" : "")}>
            <div className="photo-header">
                <div className="flex flex-row items-center pl-3 pt-3 pb-2">
                    <button
                        className="p-1 px-3"
                        onClick={() => {
                            onClose();
                            setOpenInfo(false);
                        }}
                        >
                        <i className="fa-solid fa-close"></i>
                    </button>

                    <NavLink
                        className="ml-auto mr-4"
                        to="/search"
                        onClick={event => notImplemented(event)}
                        >
                        <div className="flex flex-row items-center">
                            <i className="w-4 text-center fa-solid fa-share-nodes"></i>
                            <div className="hidden sm:block ml-2">Share</div>
                        </div>
                    </NavLink>

                    <NavLink
                        className="mr-4"
                        to="/cloud"
                    >
                        <div className="flex flex-row items-center">
                            <i className="w-4 text-center fa-regular fa-star"></i>
                            <div className="hidden sm:block ml-2">Favorite</div>
                        </div>
                    </NavLink>

                    <button
                        data-testid="open-info-button"
                        className="mr-4"
                        onClick={event => {
                            setOpenInfo(true);
                        }}
                        >
                        <div className="flex flex-row items-center">
                            <i className="w-4 text-center fa-solid fa-circle-info"></i>
                            <div className="hidden sm:block ml-2">Info</div>
                        </div>
                    </button>

                    <NavLink
                        className="mr-4"
                        to="/trash"
                        onClick={event => notImplemented(event)}
                    >
                        <div className="flex flex-row items-center">
                            <i className="w-3 text-center fa-regular fa-trash-can"></i>
                            <div className="hidden sm:block ml-2">Trash</div>
                        </div>
                    </NavLink>

                    <NavLink
                        className="mr-3"
                        to="/menu"
                        onClick={event => notImplemented(event)}
                    >
                        <div className="flex flex-row items-center">
                            <i className="w-2 text-center fa-solid fa-ellipsis-vertical"></i>
                            <div className="hidden sm:block ml-2">More</div>
                        </div>
                    </NavLink>
                </div>
            </div>

            <div className="photo-content flex-grow flex flex-col justify-center">
                <div className="flex flex-grow portrait:flex-row landscape:flex-row">
                    <div className="flex flex-col justify-center">
                        <button
                            className="p-1 px-3"
                            onClick={event => onPrev()}
                            >
                            <i className="fa-solid fa-arrow-left"></i>
                        </button>
                    </div>
                    <div className="flex-grow flex portrait:flex-col landscape:flex-row justify-center">
                        {asset && 
                            <div>
                                <img
                                    data-testid="fullsize-asset"
                                    src={api.makeUrl(`/asset?id=${asset._id}`)}
                                />
                            </div>
                        }
                    </div>
                    <div className="flex flex-col justify-center">
                        <button
                            className="p-1 px-3"
                            onClick={event => onNext()}
                            >
                            <i className="fa-solid fa-arrow-right"></i>
                        </button>
                    </div>
                </div>
            </div>

            <AssetInfo
            	key={asset._id}
                open={openInfo}
                onClose={() => {
                    setOpenInfo(false);
                }}
                />
        </div>
    );
}