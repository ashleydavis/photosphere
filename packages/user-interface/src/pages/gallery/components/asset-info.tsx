import React, { useCallback, useEffect } from "react";
import dayjs from "dayjs";
import { useGalleryItem } from "../../../context/gallery-item-context";
import _ from "lodash";
import { Textarea, IconButton, Button, Chip, Typography, Sheet } from "@mui/joy";

export interface IAssetInfoProps { 

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
export function AssetInfo({ onClose, onDeleted }: IAssetInfoProps) {

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
            <Chip
                key={name}
                variant="outlined"
                color="neutral"
                className="ml-2 mt-1"
                endDecorator={
                    <IconButton
                        size="sm"
                        variant="plain"
                        color="neutral"
                        onClick={() => onRemoveLabel(name)}
                        sx={{ minHeight: '20px', minWidth: '20px', ml: 0.5 }}
                        >
                        <i className="fa-solid fa-close text-xs" />
                    </IconButton>
                }
                >
                {name}
            </Chip>
        );
    }

    if (!asset) {
        return null; // Waiting for asset to be loaded.
    }

    return (
        <Sheet 
            className="info"
            sx={{ bgcolor: 'background.surface', color: 'text.primary' }}
            >
            <div className="info-header">
                <div className="flex flex-row items-center pl-3 pt-3 pb-2">
                    <IconButton
                        variant="plain"
                        color="neutral"
                        onClick={() => {
                            onClose();
                        }}
                        >
                        <i className="fa-solid fa-close" />
                    </IconButton>

                    <Typography level="title-lg" className="ml-2">Info</Typography>
                </div>
            </div>

            <div className="info-content flex flex-col">

                <div className="flex flex-col flex-grow ml-5 mr-5 mt-6 mb-6 justify-center">
                    <div className="flex flex-row h-8">
                        <Textarea
                            className="flex-grow"
                            placeholder="Add a description"                            
                            value={description}
                            onChange={event => onUpdateDescription(event.target.value)}
                            />
                    </div>

                    <div className="flex flex-col">
                        <div className="text-base flex flex-row mt-4 pt-2">
                            <div className="w-6 mt-2 flex flex-col items-center">
                                <i className="text-2xl fa-solid fa-calendar-day" />
                            </div>
                            <div className="flex flex-col ml-3">
                                <Typography level="body-md">Asset id</Typography>
                                <Typography
                                	data-testid="asset-id"
                                    level="body-sm"
                                    >
                                    {asset._id}
                                </Typography>
                            </div>
                        </div>

                        <div className="text-base flex flex-row mt-4 pt-2">
                            <div className="w-6 mt-2 flex flex-col items-center">
                                <i className="text-2xl fa-solid fa-calendar-day" />
                            </div>
                            <div className="flex flex-col ml-3">
                                <Typography level="body-md">Asset hash</Typography>
                                <Typography level="body-sm">
                                    {asset.hash}
                                </Typography>
                            </div>
                        </div>

                        <div className="text-lg flex flex-row portrait:mt-10 landscape:mt-4 pt-2">
                            <div className="w-6 mt-2 flex flex-col items-center">
                                <i className="text-2xl fa-solid fa-tags" />
                            </div>
                            <div className="flex flex-col ml-3">
                                <div className="flex flex-row flex-wrap items-center">
                                    {asset.labels?.map(label => {
                                        return renderLabel(label);
                                    })}

                                    <IconButton
                                        className="ml-2"
                                        variant="plain"
                                        color="neutral"
                                        onClick={onAddLabel}
                                        >
                                        <i className="fa-solid fa-square-plus" />
                                    </IconButton>
                                </div>
                            </div>
                        </div>

                        <div className="text-base flex flex-row mt-4 pt-2">
                            <div className="w-6 mt-2 flex flex-col items-center">
                                <i className="text-2xl fa-solid fa-calendar-day" />
                            </div>
                            <div className="flex flex-col ml-3">
                                <Typography level="body-md">
                                    {asset.photoDate ? dayjs(asset.photoDate).format("MMM D, YYYY") : "No date" }
                                </Typography>
                                <Typography level="body-sm">
                                    {asset.photoDate ? dayjs(asset.photoDate).format("HH:mm") : "No time" }
                                </Typography>
                            </div>
                        </div>

                        {asset.location
                            && <div className="text-base flex flex-row mt-4 pt-2">
                                <div className="w-6 mt-2 flex flex-col items-center">
                                    <i className="text-2xl fa-regular fa-map" />
                                </div>
                                <div className="flex flex-col ml-3">
                                    <Typography level="body-md">
                                        {asset.location}
                                    </Typography>
                                </div>
                            </div>
                        }

                        {/* <div className="text-base flex flex-row mt-4 pt-2">
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

                        <div className="text-base flex flex-row mt-4 pt-2">
                            <div className="w-6 mt-2 flex flex-col items-center">
                                <i className="text-2xl fa-regular fa-image" />
                            </div>
                            <div className="flex flex-col ml-3">
                                <Typography level="body-md">
                                    {asset.origPath} {asset.origFileName}
                                </Typography>
                                <Typography level="body-sm">
                                    {asset.width} × {asset.height}
                                </Typography>
                            </div>
                        </div>

                        {/* <div className="text-base flex flex-row mt-4 pt-2">
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

                        <div className="flex flex-row items-center mt-6">
                            <Button
                                variant="plain"
                                color="danger"
                                startDecorator={<i className="text-xl fa-solid fa-trash" />}
                                onClick={onDeleteItem}
                                >
                                Delete
                            </Button>
                        </div> 
                    </div>
                </div>
            </div>
        </Sheet>
    );
}