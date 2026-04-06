import React, { useEffect, useState } from "react";
import { AssetInfo } from "../pages/gallery/components/asset-info";
import { useGalleryItem } from "../context/gallery-item-context";
import { FullImage } from "./full-image";
import { Video } from "./video";
import { useGallery } from "../context/gallery-context";
import { Drawer, IconButton } from "@mui/joy";
import { Flag, Star } from "@mui/icons-material";

export interface IAssetViewProps { 

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
export function AssetView({ onClose, onNext, onPrev }: IAssetViewProps) {

    const { getNext, getPrev, selectedItems, addToMultipleSelection, removeFromMultipleSelection, enableSelecting } = useGallery();
    const { asset, addArrayValue, removeArrayValue } = useGalleryItem();

    // 
    // Set to true to open the info modal.
    //
    const [openInfo, setOpenInfo] = useState<boolean>(false);

    if (!asset) {
        return null; // Waiting for asset to be loaded.
    }

    const isStarred = asset.labels && Array.isArray(asset.labels) && asset.labels.includes("starred");
    const isFlagged = asset.labels && Array.isArray(asset.labels) && asset.labels.includes("flagged");
    const isSelected = selectedItems.has(asset._id);

    return (
        <div className="photo text-xl">
            <div className="w-full h-full flex flex-col justify-center items-center">
                <div className="photo-container flex flex-col items-center justify-center">
                    {asset.contentType.startsWith("video/")
                        && <Video
                            key={asset._id}
                            asset={asset}
                            />
                        || <FullImage
                            key={asset._id}
                            asset={asset}
                            />
                    }
                </div>

                <div className="photo-nav w-full h-full flex flex-row pointer-events-none">
                    {getPrev(asset) !== undefined
                        && <div className="flex flex-col justify-center">
                            <IconButton
                                className="ml-4 pointer-events-auto"
                                variant="outlined"
                                color="neutral"
                                onClick={() => onPrev()}
                                >
                                <i className="fa-solid fa-arrow-left"></i>
                            </IconButton>
                        </div>
                    }
                    <div className="flex-grow" /> {/* Spacer */}
                    {getNext(asset) !== undefined
                        && <div className="flex flex-col justify-center">
                            <IconButton
                                className="mr-4 pointer-events-auto"
                                variant="outlined"
                                color="neutral"
                                onClick={() => onNext()}
                                >
                                <i className="fa-solid fa-arrow-right"></i>
                            </IconButton>
                        </div>
                    }
                </div>
            </div>
            
            <div className="photo-header">
                <div className="flex flex-row items-center pl-3 pr-3 pt-3 pb-2">
                    <IconButton
                        className="pointer-events-auto"
                        variant="outlined"
                        color="neutral"
                        onClick={() => {
                            onClose();
                            setOpenInfo(false);
                        }}
                        >
                        <i className="fa-solid fa-close"></i>
                    </IconButton>

                    <div
                        className={isSelected ? "asset-view-select-btn selected" : "asset-view-select-btn"}
                        style={{
                            marginLeft: "16px",
                            width: "24px",
                            height: "24px",
                            borderRadius: "50%",
                            display: "flex",
                            justifyContent: "center",
                            alignItems: "center",
                            cursor: "pointer",
                        }}
                        title={isSelected ? "Deselect" : "Select"}
                        onClick={() => {
                            if (isSelected) {
                                removeFromMultipleSelection(asset);
                            }
                            else {
                                enableSelecting(true);
                                addToMultipleSelection(asset);
                            }
                        }}
                        >
                        <svg
                            xmlns="http://www.w3.org/2000/svg"
                            viewBox="0 0 24 24"
                            fill="white"
                            width="16px"
                            height="16px"
                            >
                            <path d="M9 16.17L4.83 12l-1.42 1.41L9 19 21 7l-1.41-1.41z" />
                        </svg>
                    </div>

                    <IconButton
                        className="pointer-events-auto"
                        variant="outlined"
                        color="neutral"
                        sx={isStarred ? { ml: 'auto', color: "gold" } : { ml: 'auto' }}
                        title={isStarred ? "Unstar" : "Star"}
                        onClick={async () => {
                            if (isStarred) {
                                await removeArrayValue("labels", "starred");
                            }
                            else {
                                await addArrayValue("labels", "starred");
                            }
                        }}
                        >
                        <Star />
                    </IconButton>

                    <IconButton
                        className="pointer-events-auto"
                        variant="outlined"
                        color="neutral"
                        sx={isFlagged ? { ml: 1, color: "red" } : { ml: 1 }}
                        title={isFlagged ? "Unflag" : "Flag"}
                        onClick={async () => {
                            if (isFlagged) {
                                await removeArrayValue("labels", "flagged");
                            }
                            else {
                                await addArrayValue("labels", "flagged");
                            }
                        }}
                        >
                        <Flag />
                    </IconButton>

                    <IconButton
                        data-testid="open-info-button"
                        className="pointer-events-auto"
                        variant="outlined"
                        color="neutral"
                        sx={{ ml: 1 }}
                        onClick={() => {
                            setOpenInfo(true);
                        }}
                        >
                        <i className="fa-solid fa-circle-info"></i>
                    </IconButton>
                </div>
            </div>

            <Drawer
                className="asset-info-drawer"
                open={openInfo}
                onClose={() => {
                    setOpenInfo(false);
                }}
                size="lg"
                anchor="bottom"
                >
                <AssetInfo
                    key={asset._id}
                    onClose={() => {
                        setOpenInfo(false);
                    }}
                    onDeleted={() => {
                        setOpenInfo(false);
                        onClose();
                    }}
                    />
            </Drawer>
        </div>
    );
}