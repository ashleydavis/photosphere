import React, { useCallback, useEffect } from "react";
import dayjs from "dayjs";
import { useGalleryItem } from "../../../context/gallery-item-context";
import _ from "lodash";

export interface IAssetInfoProps { 

    //
    // Set to true to open the asset info modal.
    //
    open: boolean;

    //
    // Event raised when the modal is closed.
    //
    onClose: () => void;

    //
    // Event raised when the asset has been deleted.
    //
    onDeleted: () => void;
}

//
// Shows info for a particular asset.
//
export function AssetInfo({ open, onClose, onDeleted }: IAssetInfoProps) {

    //
    // Interface to the gallery item.
    //
    const { asset, updateAsset, addArrayValue, removeArrayValue, deleteAsset } = useGalleryItem();

    const [description, setDescription] = React.useState(asset?.description);

    //
    // Adds a new label to the asset.
    //
    async function onAddLabel(): Promise<void> {
        const labelName = window.prompt("Enter the new label:");
        if (!labelName) {
            return;
        }

        await addArrayValue("labels", labelName);
    }
    
	//
    // Removes a label from the asset.
    //
    async function onRemoveLabel(labelName: string): Promise<void> {
        await removeArrayValue("labels", labelName);
    }

    //
    // Marks the asset as deleted.
    //
    async function onDeleteItem(): Promise<void> {
        await deleteAsset();
        onDeleted();
    }

    // 
    // Debounce the update to prevent too many updates.
    //
    const debouncedUpdateDescription = useCallback(_.debounce((description: string) => {
        updateAsset({ description });
    }, 500), []);

    //
    // Flushes the debounced description update on unmount.
    //
    useEffect(() => {
        return () => {
            debouncedUpdateDescription.flush();
        };
    }, []);
        
    //
    // Event raised when the user has updated the assets description.
    //
    async function onUpdateDescription(description: string): Promise<void> {
        setDescription(description);
        debouncedUpdateDescription(description);
    }

    //
    // Renders a label.
    //
    function renderLabel(name: string) {
        return (
            <span
                key={name}
                className="ml-2 mt-1 flex flex-wrap justify-between items-center text-sm bg-gray-100 hover:bg-gray-200 border border-gray-200 border-solid rounded pl-1 pr-1 py-0"
                >
                {name}
                <button
                    className="ml-2 p-1 pl-2 pr-1"
                    onClick={() => onRemoveLabel(name)}
                    >
                    <i className="fa-solid fa-close"></i>
                </button>
            </span>
        );
    }

    if (!asset) {
        return null; // Waiting for asset to be loaded.
    }

    return (
        <div className={"info overflow-scroll bg-white text-black " + (open ? "open" : "")}>
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

            <div className="info-content flex flex-col">

                <div className="flex flex-col flex-grow ml-5 mr-5 mt-6 mb-6 justify-center">
                    <div className="flex flex-row h-8">
                        <textarea
                            className="flex-grow border-b border-solid border-black border-opacity-20"
                            placeholder="Add a description"
                            spellCheck="false"
                            autoComplete="off"
                            value={description}
                            onChange={event => onUpdateDescription(event.target.value)}
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
                                <div className="flex flex-row flex-wrap">
                                    {asset.labels?.map(label => {
                                        return renderLabel(label);
                                    })}

                                    <button
                                        className="ml-2 p-1 pl-3 pr-3"
                                        onClick={onAddLabel}
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
                                    {asset.photoDate ? dayjs(asset.photoDate).format("MMM D, YYYY") : "No date" }
                                </div>
                                <div className="text-sm flex flex-row" >
                                    {asset.photoDate ? dayjs(asset.photoDate).format("HH:mm") : "No time" }
                                </div>
                            </div>
                        </div>

                        {asset.location
                            && <div className="text-base text-gray-600 flex flex-row mt-4 pt-2">
                                <div className="w-6 mt-2 flex flex-col items-center">
                                    <i className="text-2xl fa-regular fa-map"></i>
                                </div>
                                <div className="flex flex-col ml-3">
                                    <div>
                                        {asset.location}
                                    </div>
                                </div>
                            </div>
                        }

                        {/* <div className="text-base text-gray-600 flex flex-row mt-4 pt-2">
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
                        </div> */}

                        <div className="text-base text-gray-600 flex flex-row mt-4 pt-2">
                            <div className="w-6 mt-2 flex flex-col items-center">
                                <i className="text-2xl fa-regular fa-image"></i>
                            </div>
                            <div className="flex flex-col ml-3">
                                <div>
                                {asset.origPath} {asset.origFileName}
                                </div>
                                <div className="text-sm flex flex-row" >
                                    <div>{asset.width} × {asset.height}</div>
                                </div>
                            </div>
                        </div>

                        {/* <div className="text-base text-gray-600 flex flex-row mt-4 pt-2">
                            <div className="w-6 mt-0 flex flex-col items-center">
                                <i className="text-2xl fa-solid fa-upload"></i>
                            </div>
                            <div className="flex flex-col ml-3">
                                <div>
                                    Uploaded from Android device
                                </div>
                            </div>
                        </div>
                        */}

                        <div className="text-base text-red-600 flex flex-row items-center mt-6">
                            <button
                                className=""
                                onClick={onDeleteItem}
                                >
                                <i className="w-6 text-2xl pt-1 mr-3 text-red-600 fa-solid fa-trash"></i>
                                Delete
                            </button>
                        </div> 
                    </div>
                </div>
            </div>
        </div>
    );
}