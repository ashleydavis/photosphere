import React, { useEffect, useState } from "react";
import dayjs from "dayjs";
import { AssetInfo } from "../pages/gallery/components/asset-info";
import { useGalleryItem } from "../context/gallery-item-context";
import { Carousel } from "./carousel";
import { useGallery } from "../context/gallery-context";
import { useGallerySource } from "../context/gallery-source";
import { usePlatform } from "../context/platform-context";
import { useAssetDatabase } from "../context/asset-database-source";
import { Chip, Drawer, IconButton, Input } from "@mui/joy";
import { ContentCopy, Delete, Download, Flag, Star } from "@mui/icons-material";
import { DeleteConfirmationDialog } from "./delete-confirmation-dialog";
import { SetPhotoDateDialog } from "./set-photo-date-dialog";
import { SetLocationDialog } from "./set-location-dialog";

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

    const { getPrev, getNext, selectedItems, addToMultipleSelection, removeFromMultipleSelection, enableSelecting, search } = useGallery();
    const { loadAsset } = useGallerySource();
    const { downloadAsset, copyToClipboard } = usePlatform();
    const { databasePath } = useAssetDatabase();
    const { asset, updateAsset, addArrayValue, removeArrayValue, deleteAsset } = useGalleryItem();

    //
    // Set to true to open the info modal.
    //
    const [openInfo, setOpenInfo] = useState<boolean>(false);

    //
    // Set to true to open the set date dialog.
    //
    const [editingDate, setEditingDate] = useState<boolean>(false);

    //
    // Set to true to open the set location dialog.
    //
    const [editingLocation, setEditingLocation] = useState<boolean>(false);

    //
    // Set to true to show the delete confirmation dialog.
    //
    const [confirmingDelete, setConfirmingDelete] = useState<boolean>(false);

    //
    // Controls visibility of the inline add-label input.
    //
    const [addingLabel, setAddingLabel] = useState<boolean>(false);

    //
    // The text currently typed into the add-label input.
    //
    const [newLabelName, setNewLabelName] = useState<string>("");

    //
    // Downloads the full-resolution asset.
    //
    async function handleDownload(): Promise<void> {
        await downloadAsset(asset!._id, "asset", asset!.origFileName || asset!._id, asset!.contentType, databasePath!);
    }

    //
    // Deletes the asset.
    //
    async function handleDelete(): Promise<void> {
        await deleteAsset();
        setConfirmingDelete(false);
        onClose();
    }

    //
    // Confirms the new label and adds it to the asset.
    //
    async function onConfirmLabel(): Promise<void> {
        const trimmed = newLabelName.trim();
        if (trimmed) {
            await addArrayValue("labels", trimmed);
        }
        setNewLabelName("");
        setAddingLabel(false);
    }

    //
    // Removes a label from the asset.
    //
    async function onRemoveLabel(labelName: string): Promise<void> {
        await removeArrayValue("labels", labelName);
    }

    //
    // Copies the display version of the asset to the clipboard.
    //
    async function handleCopyToClipboard(): Promise<void> {
        const blob = await loadAsset(asset!._id, "display");
        if (blob) {
            await copyToClipboard(blob, asset!.contentType);
        }
    }

    if (!asset) {
        return null; // Waiting for asset to be loaded.
    }

    const isStarred = asset.labels && Array.isArray(asset.labels) && asset.labels.includes("starred");
    const isFlagged = asset.labels && Array.isArray(asset.labels) && asset.labels.includes("flagged");
    const isSelected = selectedItems.has(asset._id);
    const customLabels = (asset.labels || []).filter(label => label !== "starred" && label !== "flagged");

    return (
        <div className="photo text-xl">
            <div className="w-full h-full flex flex-col justify-center items-center">
                <div className="photo-container">
                    <Carousel asset={asset} />
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
                    <div style={{ flex: 1, display: "flex", flexDirection: "row", alignItems: "center" }}>
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
                    </div>

                    <div style={{ flex: 1, display: "flex", flexDirection: "row", alignItems: "center", justifyContent: "center" }}>
                        <div
                            className={isSelected ? "asset-view-select-btn selected" : "asset-view-select-btn"}
                            style={{
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
                    </div>

                    <div style={{ flex: 1, display: "flex", flexDirection: "row", alignItems: "center", justifyContent: "flex-end" }}>
                    <IconButton
                        className="pointer-events-auto"
                        variant="outlined"
                        color="neutral"
                        sx={isStarred ? { '--Icon-color': 'gold', '&:hover': { '--Icon-color': 'gold' } } : {}}
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
                        sx={isFlagged ? { ml: 1, '--Icon-color': 'red', '&:hover': { '--Icon-color': 'red' } } : { ml: 1 }}
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
                        className="pointer-events-auto"
                        variant="outlined"
                        color="neutral"
                        sx={{ ml: 1 }}
                        title="Download"
                        onClick={handleDownload}
                        >
                        <Download />
                    </IconButton>

                    <IconButton
                        className="pointer-events-auto"
                        variant="outlined"
                        color="neutral"
                        sx={{ ml: 1 }}
                        title="Copy to clipboard"
                        onClick={handleCopyToClipboard}
                        >
                        <ContentCopy />
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
            </div>


            <div
                className="pointer-events-auto"
                style={{
                    position: "absolute",
                    bottom: "16px",
                    right: "16px",
                }}
                >
                <IconButton
                    variant="outlined"
                    color="danger"
                    title="Delete"
                    onClick={() => setConfirmingDelete(true)}
                    >
                    <Delete />
                </IconButton>
            </div>

            <DeleteConfirmationDialog
                open={confirmingDelete}
                numItems={1}
                onCancel={() => setConfirmingDelete(false)}
                onDelete={handleDelete}
                />

            <SetPhotoDateDialog
                open={editingDate}
                onClose={() => setEditingDate(false)}
                currentDate={asset.photoDate}
                onSetDate={async (date) => {
                    await updateAsset({ photoDate: date });
                    setEditingDate(false);
                }}
                />

            <SetLocationDialog
                open={editingLocation}
                initialCoordinates={asset.coordinates}
                onSetLocation={async (coordinates, location) => {
                    await updateAsset({ coordinates, location });
                    setEditingLocation(false);
                }}
                onClearLocation={async () => {
                    await updateAsset({ coordinates: undefined, location: undefined });
                    setEditingLocation(false);
                }}
                onClose={() => setEditingLocation(false)}
                />

            <div
                className="pointer-events-auto"
                style={{
                    position: "absolute",
                    bottom: "16px",
                    left: "16px",
                    display: "flex",
                    flexDirection: "column",
                    gap: "8px",
                    maxWidth: "60%",
                }}
                >
                <div
                    style={{
                        display: "flex",
                        flexDirection: "row",
                        alignItems: "center",
                        gap: "6px",
                    }}
                    >
                    <span style={{ fontSize: "0.85rem", opacity: 0.85 }}>
                        {asset.photoDate ? dayjs(asset.photoDate).format("MMM D, YYYY") : "No date"}
                    </span>
                    <IconButton
                        size="sm"
                        variant="outlined"
                        color="neutral"
                        title="Edit date"
                        onClick={() => setEditingDate(true)}
                        >
                        <i className="fa-solid fa-pen text-xs" />
                    </IconButton>
                </div>

                <div
                    style={{
                        display: "flex",
                        flexDirection: "row",
                        alignItems: "center",
                        gap: "6px",
                    }}
                    >
                    <span style={{ fontSize: "0.85rem", opacity: 0.85 }}>
                        {asset.location
                            ? asset.location
                            : asset.coordinates
                                ? `${asset.coordinates.lat.toFixed(4)}, ${asset.coordinates.lng.toFixed(4)}`
                                : "No location"
                        }
                    </span>
                    <IconButton
                        size="sm"
                        variant="outlined"
                        color="neutral"
                        title="Edit location"
                        onClick={() => setEditingLocation(true)}
                        >
                        <i className="fa-solid fa-pen text-xs" />
                    </IconButton>
                </div>

                <div
                    style={{
                        display: "flex",
                        flexDirection: "row",
                        flexWrap: "wrap",
                        alignItems: "center",
                        gap: "4px",
                    }}
                    >
                {customLabels.length === 0 && !addingLabel && (
                    <span style={{ fontSize: "0.85rem", opacity: 0.85 }}>No labels</span>
                )}
                {customLabels.map(label => (
                    <Chip
                        key={label}
                        variant="outlined"
                        color="neutral"
                        onClick={() => {
                            search(`.labels="${label}"`);
                            onClose();
                        }}
                        sx={{ cursor: "pointer" }}
                        endDecorator={
                            <IconButton
                                size="sm"
                                variant="plain"
                                color="neutral"
                                onClick={event => {
                                    event.stopPropagation();
                                    onRemoveLabel(label);
                                }}
                                sx={{ minHeight: "20px", minWidth: "20px", ml: 0.5 }}
                                >
                                <i className="fa-solid fa-close text-xs" />
                            </IconButton>
                        }
                        >
                        {label}
                    </Chip>
                ))}
                {addingLabel
                    ? <Input
                        autoFocus
                        size="sm"
                        placeholder="Label name"
                        value={newLabelName}
                        onChange={event => setNewLabelName(event.target.value)}
                        onKeyDown={async event => {
                            if (event.key === "Enter") {
                                await onConfirmLabel();
                            }
                            else if (event.key === "Escape") {
                                setNewLabelName("");
                                setAddingLabel(false);
                            }
                        }}
                        onBlur={onConfirmLabel}
                        />
                    : <IconButton
                        variant="outlined"
                        color="neutral"
                        title="Add label"
                        onClick={() => setAddingLabel(true)}
                        >
                        <i className="fa-solid fa-tag" />
                    </IconButton>
                }
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
                    onLabelSearch={() => {
                        setOpenInfo(false);
                        onClose();
                    }}
                    />
            </Drawer>

        </div>
    );
}