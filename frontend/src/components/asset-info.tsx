import React from "react";
import { IGalleryItem } from "../lib/gallery-item";
import dayjs from "dayjs";

export interface IAssetInfoProps { 

    //
    // Set to true to open the asset info modal.
    //
    open: boolean;

    //
    // The asset to display in the modal.
    //
    asset?: IGalleryItem;

    //
    // Event raised when the model is closed.
    //
    onClose: () => void;
}

//
// Shows info for a particular asset.
//
export function AssetInfo({ open, asset, onClose }: IAssetInfoProps) {

    function notImplemented(event: any) {
        alert("This is a not implemented yet.");

        event.preventDefault();
        event.stopPropagation();
    }

    return (
        <div className={"info overflow-scroll " + (open ? "open" : "")}>
            <div className="info-header">
                <div className="flex flex-row items-center pl-3 pt-3 pb-2">
                    <button
                        className="p-1 px-3"
                        onClick={() => {
                            onClose();
                        }}
                    >
                        <i className="fa-solid fa-close"></i>
                    </button>

                    <h1 className="text-xl ml-2">Info</h1>
                </div>
            </div>

            {asset
                && <div className="info-content flex flex-col">

                    <div className="flex flex-col flex-grow ml-5 mr-5 mt-6 mb-6 justify-center">
                        <div className="flex flex-row h-8">
                            <textarea
                                className="flex-grow border-b border-solid border-black border-opacity-20"
                                placeholder="Add a description"
                                spellCheck="false"
                                autoComplete="off"
                            >
                            </textarea>
                        </div>

                        <div className="flex flex-col">
                            <div className="text-base text-gray-600 flex flex-row mt-4 pt-2">
                                <div className="w-6 mt-2 flex flex-col items-center">
                                    <i className="text-2xl fa-solid fa-calendar-day"></i>
                                </div>
                                <div className="flex flex-col ml-3">
                                    <div>
                                        Asset id
                                    </div>
                                    <div
                                		data-testid="asset-id"
                                        className="text-sm flex flex-row" 
                                        >
                                        <div>{asset._id}</div>
                                    </div>
                                </div>
                            </div>

                            <div className="text-base text-gray-600 flex flex-row mt-4 pt-2">
                                <div className="w-6 mt-2 flex flex-col items-center">
                                    <i className="text-2xl fa-solid fa-calendar-day"></i>
                                </div>
                                <div className="flex flex-col ml-3">
                                    <div>
                                        Asset hash
                                    </div>
                                    <div
                                        className="text-sm flex flex-row" 
                                        >
                                        <div>{asset.hash}</div>
                                    </div>
                                </div>
                            </div>

                            <div className="text-lg text-gray-600 flex flex-row portrait:mt-10 landscape:mt-4 pt-2">
                                <div className="w-6 mt-2 flex flex-col items-center">
                                    <i className="text-2xl fa-solid fa-tags"></i>
                                </div>
                                <div className="flex flex-col ml-3">
                                    <div className="flex flex-row">
                                        <span
                                            className="flex flex-wrap justify-between items-center text-sm bg-gray-100 hover:bg-gray-200 border border-gray-200 border-solid rounded pl-1 pr-1 py-0">
                                            Label 1
                                            <button
                                                className="ml-1 p-1 pl-2 pr-1"
                                                onClick={event => notImplemented(event)}
                                                >
                                                <i className="fa-solid fa-close"></i>
                                            </button>
                                        </span>
                                        <span
                                            className="ml-2 flex flex-wrap justify-between items-center text-sm bg-gray-100 hover:bg-gray-200 border border-gray-200 border-solid rounded pl-1 pr-1 py-0">
                                            Label 2
                                            <button
                                                className="ml-2 p-1 pl-2 pr-1"
                                                onClick={event => notImplemented(event)}
                                                >
                                                <i className="fa-solid fa-close"></i>
                                            </button>
                                        </span>

                                        <button
                                            className="ml-2 p-1 pl-3 pr-3"
                                            onClick={event => notImplemented(event)}
                                            >
                                            <i className="fa-solid fa-square-plus"></i>
                                        </button>
                                    </div>
                                </div>
                            </div>

                            <div className="text-base text-gray-600 flex flex-row mt-4 pt-2">
                                <div className="w-6 mt-2 flex flex-col items-center">
                                    <i className="text-2xl fa-solid fa-calendar-day"></i>
                                </div>
                                <div className="flex flex-col ml-3">
                                    <div>
                                        {dayjs(asset?.photoDate || asset?.fileDate).format("MMM D, YYYY")}
                                    </div>
                                    <div className="text-sm flex flex-row" >
                                        <div>{dayjs(asset?.photoDate || asset?.fileDate).format("HH:mm")}</div>
                                        <div className="ml-4">GMT+10:00</div>
                                    </div>
                                </div>
                            </div>

                            <div className="text-base text-gray-600 flex flex-row mt-4 pt-2">
                                <div className="w-6 mt-2 flex flex-col items-center">
                                    <i className="text-2xl fa-solid fa-camera"></i>
                                </div>
                                <div className="flex flex-col ml-3">
                                    <div>
                                        Google Pixel 6
                                    </div>
                                    <div className="text-sm flex flex-row" >
                                        <div>ƒ/1.85</div>
                                        <div className="ml-4">1/177</div>
                                        <div className="ml-4">6.81mm</div>
                                        <div className="ml-4">ISO368</div>
                                    </div>
                                </div>
                            </div>

                            <div className="text-base text-gray-600 flex flex-row mt-4 pt-2">
                                <div className="w-6 mt-2 flex flex-col items-center">
                                    <i className="text-2xl fa-regular fa-image"></i>
                                </div>
                                <div className="flex flex-col ml-3">
                                    <div>
                                        PXL_20230102_070227920.jpg
                                    </div>
                                    <div className="text-sm flex flex-row" >
                                        <div>4.9MP</div>
                                        <div className="ml-4">1920 × 2560</div>
                                    </div>
                                </div>
                            </div>

                            <div className="text-base text-gray-600 flex flex-row mt-4 pt-2">
                                <div className="w-6 mt-0 flex flex-col items-center">
                                    <i className="text-2xl fa-solid fa-upload"></i>
                                </div>
                                <div className="flex flex-col ml-3">
                                    <div>
                                        Uploaded from Android device
                                    </div>
                                </div>
                            </div>
                        </div>
                    </div>
                </div>
            }
        </div>
    );
}