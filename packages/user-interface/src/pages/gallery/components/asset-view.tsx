import React, { useState } from "react";
import { useApi } from "../../../context/api-context";
import { AssetInfo } from "./asset-info";
import { useGalleryItem } from "../../../context/gallery-item-context";

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
    const [openInfo, setOpenInfo] = useState<boolean>(false);

    return (
        <div className={"photo bg-black text-white text-xl " + (open ? "open" : "")}>

            <div className="w-full h-full flex flex-col justify-center items-center">
                {open
                    && <div className="photo-container flex flex-col items-center justify-center">
                        <img
                            data-testid="fullsize-asset"
                            src={asset.url || api.makeUrl(`/display?id=${asset._id}`)}
                            />
                    </div>
                }

                <div className="photo-nav w-full h-full flex flex-row">
                    <div className="flex flex-col justify-center">
                        <button
                            className="p-1 px-3"
                            onClick={() => onPrev()}
                            >
                            <i className="text-white fa-solid fa-arrow-left"></i>
                        </button>
                    </div>
                    <div className="flex-grow" /> {/* Spacer */}
                    <div className="flex flex-col justify-center">
                        <button
                            className="p-1 px-3"
                            onClick={() => onNext()}
                            >
                            <i className="text-white fa-solid fa-arrow-right"></i>
                        </button>
                    </div>
                </div>
            </div>
            
            <div className="photo-header">
                <div className="flex flex-row items-center pl-3 pt-3 pb-2">
                    <button
                        className="p-1 px-3"
                        onClick={() => {
                            onClose();
                            setOpenInfo(false);
                        }}
                        >
                        <i className="text-white fa-solid fa-close"></i>
                    </button>

                    <button
                        data-testid="open-info-button"
                        className="ml-auto mr-4"
                        onClick={event => {
                            setOpenInfo(true);
                        }}
                        >
                        <div className="flex flex-row items-center">
                            <i className="w-4 text-white text-center fa-solid fa-circle-info"></i>
                            <div className="hidden sm:block ml-2">Info</div>
                        </div>
                    </button>
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