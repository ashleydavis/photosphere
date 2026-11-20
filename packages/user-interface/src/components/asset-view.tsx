import React, { useEffect, useLayoutEffect, useRef, useState } from "react";
import dayjs from "dayjs";
import { AssetInfo } from "../pages/gallery/components/asset-info";
import { useGalleryItem } from "../context/gallery-item-context";
import { Carousel, FILM_STRIP_HEIGHT } from "./carousel";
import { useGallery } from "../context/gallery-context";
import { useGallerySource } from "../context/gallery-source";
import { usePlatform } from "../context/platform-context";
import { useAssetDatabase } from "../context/asset-database-source";
import { useStateStore } from "../context/state-store-context";
import { Chip, Drawer, IconButton } from "@mui/material";
import { ContentCopy, Delete, Download, Flag, Star } from "@mui/icons-material";
import { DeleteConfirmationDialog } from "./delete-confirmation-dialog";
import { dedupeLabels } from "../lib/labels";
import { formatCoordinates } from "../lib/coordinates";
import { useIsMobile } from "../lib/use-is-mobile";
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
// Session-level cache of the summary card's collapsed state, seeded from the state store.
// Lets the state apply synchronously when reopening an asset, avoiding a flash before config loads.
//
let summaryCollapsedCache: boolean | undefined = undefined;

//
// The height of the viewer's top bar: a viewer control and the room above and below it, as in the
// style guide's viewer. The photo starts below it.
//
const BAR_HEIGHT = "calc(var(--button-height-md) + var(--space-2) * 2)";

//
// The style of a label chip in the quick info card: an outline in the viewer control colours on
// the card's glass, so it reads over any photo, as the style guide's quick info labels do.
//
const QUICK_INFO_CHIP_SX = {
    cursor: "pointer",
    backgroundColor: "transparent",
    color: "inherit",
    borderColor: "var(--color-viewer-control-border)",
    "&:hover": {
        backgroundColor: "var(--color-viewer-control-border)",
    },
};

//
// Shows info for a particular asset.
//
export function AssetView({ onClose, onNext, onPrev }: IAssetViewProps) {

    const { getPrev, getNext, selectedItems, addToMultipleSelection, removeFromMultipleSelection, enableSelecting, search } = useGallery();
    const { loadAsset } = useGallerySource();
    const { copyToClipboard } = usePlatform();
    const { downloadAsset } = useAssetDatabase();
    const { asset, addArrayValue, removeArrayValue, deleteAsset } = useGalleryItem();
    const state = useStateStore();
    const isMobile = useIsMobile();

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
        state.get<boolean>(SUMMARY_COLLAPSED_KEY)
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
        const rowGap = parseFloat(getComputedStyle(container).rowGap);
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
        await state.set(SUMMARY_COLLAPSED_KEY, collapsed);
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

    let selectButtonSx = {};
    if (isSelected) {
        selectButtonSx = {
            color: "var(--color-on-accent)",
            backgroundColor: "var(--color-accent)",
            borderColor: "var(--color-accent)",
            "&:hover": {
                color: "var(--color-on-accent)",
                backgroundColor: "var(--color-accent)",
            },
        };
    }

    let starIconColor: string | undefined = undefined;
    if (isStarred) {
        starIconColor = "var(--color-viewer-starred)";
    }

    let flagIconColor: string | undefined = undefined;
    if (isFlagged) {
        flagIconColor = "var(--color-viewer-flagged)";
    }

    let detailsAnchor: "right" | "bottom" = "right";
    let detailsPaperSx = {
        width: "calc(var(--space-8) * 11)",
        maxWidth: "100%",
        maxHeight: "none",
        backgroundColor: "var(--color-details-panel-bg)",
        boxShadow: "var(--shadow-details-panel)",
        borderRadius: "var(--radius-details-panel)",
        borderRight: "none",
        borderLeft: "1px solid var(--color-border)",
    };
    let detailsBackdropSx = {
        backgroundColor: "transparent",
        backdropFilter: "none",
    };
    if (isMobile) {
        detailsAnchor = "bottom";
        detailsPaperSx = {
            width: "auto",
            maxWidth: "none",
            maxHeight: "78%",
            backgroundColor: "var(--color-panel)",
            boxShadow: "var(--shadow-overlay)",
            borderRadius: "var(--radius-lg) var(--radius-lg) 0 0",
            borderRight: "none",
            borderLeft: "none",
        };
        detailsBackdropSx = {
            backgroundColor: "var(--color-scrim)",
            backdropFilter: "blur(var(--backdrop-blur))",
        };
    }

    return (
        <div
            className="photosphere-viewer absolute inset-0"
            style={{
                background: "var(--color-viewer-bg)",
            }}
            >
            <div
                className="absolute"
                style={{
                    top: "env(safe-area-inset-top)",
                    right: "env(safe-area-inset-right)",
                    bottom: "env(safe-area-inset-bottom)",
                    left: "env(safe-area-inset-left)",
                }}
                >
                <div
                    className="absolute inset-x-0 bottom-0 overflow-hidden"
                    style={{
                        top: BAR_HEIGHT,
                    }}
                    >
                    <Carousel asset={asset} />
                </div>

                <div
                    className="absolute inset-x-0 top-0 flex items-center"
                    style={{
                        height: BAR_HEIGHT,
                        gap: "var(--space-2)",
                        padding: "0 var(--space-2)",
                        background: "var(--viewer-bar-bg)",
                        color: "var(--color-viewer-control-text)",
                    }}
                    >
                    <IconButton
                        data-id="asset-view-close-button"
                        className="photosphere-viewer-button"
                        title="Close"
                        onClick={() => {
                            onClose();
                            setOpenInfo(false);
                        }}
                        >
                        <i className="fa-solid fa-close"></i>
                    </IconButton>

                    <IconButton
                        className="photosphere-viewer-button"
                        sx={selectButtonSx}
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
                            fill="currentColor"
                            width="1em"
                            height="1em"
                            >
                            <path d="M9 16.17L4.83 12l-1.42 1.41L9 19 21 7l-1.41-1.41z" />
                        </svg>
                    </IconButton>

                    <div className="min-w-0 flex-1" />

                    <div className="flex flex-none items-center [--color-viewer-control-fill:var(--viewer-actions-button-fill)] [gap:var(--viewer-actions-gap)] [padding:var(--viewer-actions-padding)] [background:var(--color-viewer-actions-bg)] [border:1px_solid_var(--color-viewer-actions-border)] [border-radius:var(--radius-full)] [backdrop-filter:blur(var(--viewer-actions-blur))]">
                        <IconButton
                            className="photosphere-viewer-button"
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
                            <Star
                                fontSize="inherit"
                                sx={{
                                    color: starIconColor,
                                }}
                                />
                        </IconButton>

                        <IconButton
                            className="photosphere-viewer-button"
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
                            <Flag
                                fontSize="inherit"
                                sx={{
                                    color: flagIconColor,
                                }}
                                />
                        </IconButton>

                        <IconButton
                            data-id="download-asset-button"
                            className="photosphere-viewer-button"
                            title="Download"
                            onClick={handleDownload}
                            >
                            <Download fontSize="inherit" />
                        </IconButton>

                        <IconButton
                            className="photosphere-viewer-button"
                            title="Copy to clipboard"
                            onClick={handleCopyToClipboard}
                            >
                            <ContentCopy fontSize="inherit" />
                        </IconButton>

                        <IconButton
                            data-testid="open-info-button"
                            data-id="open-info-button"
                            className="photosphere-viewer-button"
                            title="Asset info"
                            onClick={() => {
                                setOpenInfo(true);
                            }}
                            >
                            <i className="fa-solid fa-circle-info"></i>
                        </IconButton>
                    </div>
                </div>

                {getPrev(asset) !== undefined
                    && <div
                        className="absolute"
                        style={{
                            left: "var(--space-2)",
                            top: "50%",
                            transform: "translateY(-50%)",
                        }}
                        >
                        <IconButton
                            className="photosphere-viewer-button"
                            title="Previous"
                            onClick={() => onPrev()}
                            >
                            <i className="fa-solid fa-arrow-left"></i>
                        </IconButton>
                    </div>
                }

                {getNext(asset) !== undefined
                    && <div
                        className="absolute"
                        style={{
                            right: "var(--space-2)",
                            top: "50%",
                            transform: "translateY(-50%)",
                        }}
                        >
                        <IconButton
                            className="photosphere-viewer-button"
                            title="Next"
                            onClick={() => onNext()}
                            >
                            <i className="fa-solid fa-arrow-right"></i>
                        </IconButton>
                    </div>
                }

                <div
                    className="absolute flex items-end pointer-events-none"
                    style={{
                        left: "var(--space-2)",
                        right: "var(--space-2)",
                        bottom: `calc(${FILM_STRIP_HEIGHT} + var(--space-2))`,
                        gap: "var(--space-2)",
                    }}
                    >
                    <div
                        className="pointer-events-auto flex min-w-0 flex-col"
                        style={{
                            display: "var(--quick-info-display)",
                            flex: "var(--quick-info-grow) 1 auto",
                            maxWidth: "var(--quick-info-max-width)",
                            padding: "var(--space-2) var(--space-2) var(--space-2) var(--space-3)",
                            background: "var(--color-quick-info-bg)",
                            border: "1px solid var(--color-viewer-control-border)",
                            borderRadius: "var(--radius-quick-info)",
                            color: "var(--color-viewer-control-text)",
                            backdropFilter: "blur(var(--viewer-control-blur))",
                            WebkitBackdropFilter: "blur(var(--viewer-control-blur))",
                            fontSize: "var(--text-sm)",
                        }}
                        >
                        <div
                            className="flex items-center"
                            style={{
                                gap: "var(--space-2)",
                            }}
                            >
                            <span
                                className="min-w-0 flex-1 truncate"
                                style={{
                                    fontWeight: "var(--weight-bold)",
                                    cursor: "pointer",
                                }}
                                title={summaryCollapsed ? "Expand details" : "Collapse details"}
                                onClick={toggleSummaryCollapsed}
                                >
                                Quick Info
                            </span>
                            <IconButton
                                size="small"
                                className="photosphere-viewer-button"
                                title="Open full details"
                                onClick={() => setOpenInfo(true)}
                                >
                                <i className="fa-solid fa-circle-info" />
                            </IconButton>
                            <IconButton
                                size="small"
                                className="photosphere-viewer-button"
                                title={summaryCollapsed ? "Expand details" : "Collapse details"}
                                onClick={toggleSummaryCollapsed}
                                >
                                <i className={summaryCollapsed ? "fa-solid fa-chevron-right" : "fa-solid fa-chevron-left"} />
                            </IconButton>
                        </div>

                        <div
                            className="grid"
                            style={{
                                gridTemplateColumns: summaryCollapsed ? "0fr" : "1fr",
                                gridTemplateRows: summaryCollapsed ? "0fr" : "1fr",
                                transition: "grid-template-columns var(--duration-normal) var(--ease-standard), grid-template-rows var(--duration-normal) var(--ease-standard)",
                            }}
                            >
                            <div className="min-h-0 min-w-0 overflow-hidden">
                                <div
                                    className="flex flex-col"
                                    style={{
                                        gap: "var(--space-2)",
                                        width: "fit-content",
                                        paddingTop: "var(--space-2)",
                                        paddingRight: "var(--space-1)",
                                    }}
                                    >
                                    <div
                                        className="flex flex-row flex-wrap items-center"
                                        style={{
                                            gap: "var(--space-1) var(--space-2)",
                                        }}
                                        >
                                        <i className="fa-solid fa-calendar-day" title="Date" />
                                        <span>
                                            {asset.photoDate ? dayjs(asset.photoDate).format("MMM D, YYYY") : "No date"}
                                        </span>
                                        <i
                                            className="fa-solid fa-location-dot"
                                            style={{
                                                marginLeft: "var(--space-4)",
                                            }}
                                            title="Location"
                                            />
                                        <span>
                                            {asset.location
                                                ? asset.location
                                                : asset.coordinates
                                                    ? formatCoordinates(asset.coordinates)
                                                    : "No location"
                                            }
                                        </span>
                                    </div>

                                    <div className="relative">
                                        <div
                                            ref={labelsContainerRef}
                                            className="flex flex-row flex-wrap items-center overflow-hidden"
                                            style={{
                                                gap: "var(--space-1)",
                                                maxHeight: labelsMaxHeight !== undefined ? `${labelsMaxHeight}px` : undefined,
                                            }}
                                            >
                                            <i
                                                className="fa-solid fa-tags"
                                                style={{
                                                    marginRight: "var(--space-1)",
                                                }}
                                                title="Labels"
                                                />
                                            {customLabels.length === 0 && (
                                                <span>No labels</span>
                                            )}
                                            {customLabels.map(label => (
                                                <Chip
                                                    key={label}
                                                    data-label-chip
                                                    variant="outlined"
                                                    size="small"
                                                    label={label}
                                                    onClick={() => {
                                                        search(`.labels="${label}"`);
                                                        onClose();
                                                    }}
                                                    sx={QUICK_INFO_CHIP_SX}
                                                    />
                                            ))}
                                        </div>
                                        {labelsOverflow && (
                                            <Chip
                                                size="small"
                                                label="…"
                                                title="Show all labels"
                                                onClick={() => setOpenInfo(true)}
                                                sx={{
                                                    ...QUICK_INFO_CHIP_SX,
                                                    position: "absolute",
                                                    right: 0,
                                                    bottom: 0,
                                                    backgroundColor: "var(--color-quick-info-bg)",
                                                }}
                                                />
                                        )}
                                    </div>
                                </div>
                            </div>
                        </div>
                    </div>

                    <div className="flex-1" />

                    <div className="pointer-events-auto">
                        <IconButton
                            className="photosphere-viewer-button photosphere-danger"
                            title="Delete"
                            onClick={() => setConfirmingDelete(true)}
                            >
                            <Delete fontSize="inherit" />
                        </IconButton>
                    </div>
                </div>
            </div>

            <DeleteConfirmationDialog
                open={confirmingDelete}
                numItems={1}
                onCancel={() => setConfirmingDelete(false)}
                onDelete={handleDelete}
                />

            <Drawer
                className="asset-info-drawer"
                open={openInfo}
                onClose={() => {
                    setOpenInfo(false);
                }}
                anchor={detailsAnchor}
                slotProps={{
                    paper: {
                        sx: {
                            ...detailsPaperSx,
                            overflowY: "auto",
                        },
                    },
                    backdrop: {
                        sx: detailsBackdropSx,
                    },
                }}
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
