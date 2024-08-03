import React, { useEffect, useState } from "react";
import { AssetInfo } from "../pages/gallery/components/asset-info";
import { useGalleryItem } from "../context/gallery-item-context";
import { Image } from "./image";
import { Video } from "./video";
import { useGallery } from "../context/gallery-context";

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

    const { getSearchedItems, getNext, getPrev } = useGallery();
    const { asset } = useGalleryItem();

    // 
    // Set to true to open the info modal.
    //
    const [openInfo, setOpenInfo] = useState<boolean>(false);

    if (!asset) {
        return null; // Waiting for asset to be loaded.
    }

    return (
        <div className={"photo bg-black text-white text-xl " + (open ? "open" : "")}>

            <div className="w-full h-full flex flex-col justify-center items-center">
                {open
                    && <div className="photo-container flex flex-col items-center justify-center">
                        {asset.contentType.startsWith("video/")
                            && <Video
                                asset={asset}
                                />
                            || <Image                                
                                asset={asset}
                                />
                        }
                    </div>
                }

                <div className="photo-nav w-full h-full flex flex-row pointer-events-none">
                    {getPrev(asset) !== undefined
                        && <div className="flex flex-col justify-center">
                            <button
                                className="ml-4 p-1 px-3 pointer-events-auto rounded border border-solid border-white"
                                style={{
                                    backgroundColor: "rgba(0, 0, 255, 0.2)",
                                }}
                                onClick={() => onPrev()}
                                >
                                <i className="text-white fa-solid fa-arrow-left"></i>
                            </button>
                        </div>
                    }
                    <div className="flex-grow" /> {/* Spacer */}
                    {getNext(asset) !== undefined
                        && <div className="flex flex-col justify-center">
                            <button
                                className="mr-4 p-1 px-3 pointer-events-auto rounded border border-solid border-white"
                                style={{
                                    backgroundColor: "rgba(0, 0, 255, 0.2)",
                                }}
                                onClick={() => onNext()}
                                >
                                <i className="text-white fa-solid fa-arrow-right"></i>
                            </button>
                        </div>
                    }
                </div>
            </div>
            
            <div className="photo-header">
                <div className="flex flex-row items-center pl-3 pt-3 pb-2">
                    <button
                        className="p-1 px-3 pointer-events-auto rounded border border-solid border-white"
                        style={{
                            backgroundColor: "rgba(0, 0, 255, 0.2)",
                        }}
                        onClick={() => {
                            onClose();
                            setOpenInfo(false);
                        }}
                        >
                        <i className="text-white fa-solid fa-close"></i>
                    </button>

                    <button
                        data-testid="open-info-button"
                        className="ml-auto mr-4 p-1 px-3 pointer-events-auto rounded border border-solid border-white"
                        style={{
                            backgroundColor: "rgba(0, 0, 255, 0.2)",
                        }}
                        onClick={event => {
                            setOpenInfo(true);
                        }}
                        >
                        <div className="flex flex-row items-center">
                            <i className="w-4 text-white text-center fa-solid fa-circle-info"></i>
                            <div className="text-white hidden sm:block ml-2">Info</div>
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
                onDeleted={() => {
                    setOpenInfo(false);
                    onClose();
                }}
                />
        </div>
    );
}