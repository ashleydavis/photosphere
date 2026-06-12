import React, { useEffect, useLayoutEffect, useRef, useState } from "react";
import dayjs from "dayjs";
import { AssetInfo } from "../pages/gallery/components/asset-info";
import { useGalleryItem } from "../context/gallery-item-context";
import { Carousel } from "./carousel";
import { useGallery } from "../context/gallery-context";
import { useGallerySource } from "../context/gallery-source";
import { usePlatform } from "../context/platform-context";
import { useAssetDatabase } from "../context/asset-database-source";
import { useConfig } from "../context/config-context";
import { Chip, Drawer, IconButton } from "@mui/joy";
import { ContentCopy, Delete, Download, Flag, Star } from "@mui/icons-material";
import { DeleteConfirmationDialog } from "./delete-confirmation-dialog";
import { dedupeLabels } from "../lib/labels";
import { formatCoordinates } from "../lib/coordinates";
import { log } from "utils";

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
// Config key under which the summary card's collapsed state is persisted across restarts.
//
const SUMMARY_COLLAPSED_KEY = "assetSummaryCollapsed";

//
// Session-level cache of the summary card's collapsed state, seeded from persisted config.
// Lets the state apply synchronously when reopening an asset, avoiding a flash before config loads.
//
let summaryCollapsedCache: boolean | undefined = undefined;

//
// Shows info for a particular asset.
//
export function AssetView({ onClose, onNext, onPrev }: IAssetViewProps) {

    const { getPrev, getNext, selectedItems, addToMultipleSelection, removeFromMultipleSelection, enableSelecting, search } = useGallery();
    const { loadAsset } = useGallerySource();
    const { copyToClipboard } = usePlatform();
    const { downloadAsset } = useAssetDatabase();
    const { asset, addArrayValue, removeArrayValue, deleteAsset } = useGalleryItem();
    const config = useConfig();

    //
    // Set to true to open the info modal.
    //
    const [openInfo, setOpenInfo] = useState<boolean>(false);

    //
    // Set to true to show the delete confirmation dialog.
    //
    const [confirmingDelete, setConfirmingDelete] = useState<boolean>(false);

    //
    // Reference to the quick-info labels container, used to detect when labels overflow two rows.
    //
    const labelsContainerRef = useRef<HTMLDivElement>(null);

    //
    // True when the quick-info labels wrap onto more than two rows and are clamped with an ellipsis.
    //
    const [labelsOverflow, setLabelsOverflow] = useState<boolean>(false);

    //
    // Maximum height (in pixels) for the quick-info labels container, sized to fit exactly two rows.
    //
    const [labelsMaxHeight, setLabelsMaxHeight] = useState<number | undefined>(undefined);

    //
    // Whether the summary card is collapsed to just its header. Persisted across restarts.
    //
    const [summaryCollapsed, setSummaryCollapsed] = useState<boolean>(summaryCollapsedCache ?? false);

    useEffect(() => {
        log.event("AssetView opened");
    }, []);

    //
    // Loads the persisted collapsed state for the summary card on mount.
    //
    useEffect(() => {
        let cancelled = false;
        config.get<boolean>(SUMMARY_COLLAPSED_KEY)
            .then(stored => {
                if (!cancelled && stored !== undefined) {
                    summaryCollapsedCache = stored;
                    setSummaryCollapsed(stored);
                }
            });
        return () => {
            cancelled = true;
        };
    }, []);

    //
    // Measures the quick-info labels after layout to clamp them to two rows and detect overflow.
    //
    useLayoutEffect(() => {
        const container = labelsContainerRef.current;
        if (!container) {
            return;
        }
        const labelChips = Array.from(container.children).filter(child => child.hasAttribute("data-label-chip")) as HTMLElement[];
        if (labelChips.length === 0) {
            setLabelsOverflow(false);
            setLabelsMaxHeight(undefined);
            return;
        }
        const rowGap = 4;
        const rowTops: number[] = [];
        for (const chip of labelChips) {
            if (!rowTops.some(top => Math.abs(top - chip.offsetTop) < 1)) {
                rowTops.push(chip.offsetTop);
            }
        }
        const chipHeight = labelChips[0].offsetHeight;
        setLabelsMaxHeight(chipHeight * 2 + rowGap);
        setLabelsOverflow(rowTops.length > 2);
    }, [asset?.labels, summaryCollapsed]);

    //
    // Toggles the summary card between collapsed and expanded, persisting the choice.
    //
    async function toggleSummaryCollapsed(): Promise<void> {
        const collapsed = !summaryCollapsed;
        setSummaryCollapsed(collapsed);
        summaryCollapsedCache = collapsed;
        await config.set(SUMMARY_COLLAPSED_KEY, collapsed);
    }

    //
    // Downloads the full-resolution asset.
    //
    async function handleDownload(): Promise<void> {
        await downloadAsset(asset!);
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
    const customLabels = dedupeLabels((asset.labels || []).filter(label => label !== "starred" && label !== "flagged"));

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
                                className="ml-4 pointer-events-auto photo-nav-btn"
                                variant="outlined"
                                color="neutral"
                                title="Previous"
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
                                className="mr-4 pointer-events-auto photo-nav-btn"
                                variant="outlined"
                                color="neutral"
                                title="Next"
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
                            title="Close"
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
                        data-id="download-asset-button"
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
                        title="Asset info"
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

            <div
                className="pointer-events-auto"
                data-joy-color-scheme="dark"
                style={{
                    position: "absolute",
                    bottom: "16px",
                    left: "16px",
                    zIndex: 2100,
                    maxWidth: "min(425px, 75%)",
                }}
                >
                <div className="asset-summary-panel">
                    <div className="summary-header">
                        <span
                            className="summary-title"
                            style={{ flex: 1, cursor: "pointer" }}
                            title={summaryCollapsed ? "Expand details" : "Collapse details"}
                            onClick={toggleSummaryCollapsed}
                            >
                            Quick Info
                        </span>
                        <IconButton
                            size="sm"
                            variant="plain"
                            color="neutral"
                            title="Open full details"
                            onClick={() => setOpenInfo(true)}
                            >
                            <i className="fa-solid fa-circle-info text-xs" />
                        </IconButton>
                        <IconButton
                            className="asset-summary-toggle"
                            size="sm"
                            variant="plain"
                            color="neutral"
                            title={summaryCollapsed ? "Expand details" : "Collapse details"}
                            onClick={toggleSummaryCollapsed}
                            >
                            <i className={summaryCollapsed ? "fa-solid fa-chevron-right" : "fa-solid fa-chevron-left"} />
                        </IconButton>
                    </div>

                    <div className={summaryCollapsed ? "asset-summary-collapse collapsed" : "asset-summary-collapse"}>
                        <div className="asset-summary-collapse-inner">
                            <div className="asset-summary-body">
                                <div
                                    style={{
                                        display: "flex",
                                        flexDirection: "row",
                                        flexWrap: "wrap",
                                        alignItems: "center",
                                        gap: "4px 8px",
                                        fontSize: "0.85rem",
                                        opacity: 0.85,
                                    }}
                                    >
                                    <i className="fa-solid fa-calendar-day" style={{ opacity: 0.7 }} title="Date" />
                                    <span>
                                        {asset.photoDate ? dayjs(asset.photoDate).format("MMM D, YYYY") : "No date"}
                                    </span>
                                    <i className="fa-solid fa-location-dot" style={{ opacity: 0.7, marginLeft: "16px" }} title="Location" />
                                    <span>
                                        {asset.location
                                            ? asset.location
                                            : asset.coordinates
                                                ? formatCoordinates(asset.coordinates)
                                                : "No location"
                                        }
                                    </span>
                                </div>

                                <div style={{ position: "relative" }}>
                                    <div
                                        ref={labelsContainerRef}
                                        style={{
                                            display: "flex",
                                            flexDirection: "row",
                                            flexWrap: "wrap",
                                            alignItems: "center",
                                            gap: "4px",
                                            maxHeight: labelsMaxHeight !== undefined ? `${labelsMaxHeight}px` : undefined,
                                            overflow: "hidden",
                                        }}
                                        >
                                        <i className="fa-solid fa-tags" style={{ opacity: 0.7, marginRight: "2px" }} title="Labels" />
                                        {customLabels.length === 0 && (
                                            <span style={{ fontSize: "0.85rem", opacity: 0.85 }}>No labels</span>
                                        )}
                                        {customLabels.map(label => (
                                            <Chip
                                                key={label}
                                                data-label-chip
                                                variant="outlined"
                                                color="neutral"
                                                onClick={() => {
                                                    search(`.labels="${label}"`);
                                                    onClose();
                                                }}
                                                sx={{ cursor: "pointer" }}
                                                >
                                                {label}
                                            </Chip>
                                        ))}
                                    </div>
                                    {labelsOverflow && (
                                        <Chip
                                            variant="soft"
                                            color="neutral"
                                            title="Show all labels"
                                            onClick={() => setOpenInfo(true)}
                                            sx={{
                                                cursor: "pointer",
                                                position: "absolute",
                                                right: 0,
                                                bottom: 0,
                                            }}
                                            >
                                            …
                                        </Chip>
                                    )}
                                </div>
                            </div>
                        </div>
                    </div>
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