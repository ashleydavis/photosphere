import React, { useEffect, useState } from "react";
import { log } from "utils";
import { useGallery } from "../context/gallery-context";
import { IGalleryItem } from "../lib/gallery-item";
import { useLongPress } from "../lib/long-press";
import { isRecentArrival } from "../lib/recent-arrivals";

export interface IGalleryImageProps {
    //
    // The gallery item to render.
    //
    item: IGalleryItem;

    //
    // Event raised when an item in the gallery has been clicked.
    //
    onClick: (() => void) | undefined;

    //
    // X position of the image.
    //
    x: number;

    //
    // Y position of the image.
    //
    y: number;

    //
    // Width of the image.
    //
    width: number;

    //
    // Height of the image.
    //
    height: number;
}

//
// Renders an image for the gallery.
//
export function GalleryImage({ item, onClick, x, y, width, height }: IGalleryImageProps) {
    const [microDataURL, setMicroDataURL] = useState<string | undefined>(item.micro != undefined ? `data:image/jpeg;base64,${item.micro}` : undefined);
    const [thumbObjectURL, setThumbObjectURL] = useState<string | undefined>(undefined);
    const [isHovered, setIsHovered] = useState<boolean>(false);

    // Whether this photo arrived on its own just now, decided once when the thumbnail first appears
    // so scrolling it out of view and back does not play the animation a second time.
    const [isNewArrival] = useState<boolean>(() => isRecentArrival(item._id, Date.now()));

    const { loadAsset, unloadAsset, addToMultipleSelection, removeFromMultipleSelection, selectedItems, isSelecting, enableSelecting, addArrayValue, removeArrayValue, lastSelectedItemId, setLastSelectedItemId, selectRange } = useGallery();

    useEffect(() => {
        if (thumbObjectURL) {
            // Already loaded.
            return;
        }

        loadAsset(item._id, "thumb")
            .then(assetLoaded => {
                if (assetLoaded) {
                    setThumbObjectURL(assetLoaded.objectUrl);
                    setTimeout(() => {
                        setMicroDataURL(undefined);
                    }, 1200);
                }
            })
            .catch(err => {
                log.exception(`Failed to load asset: thumb:${item._id}`, err as Error);
            });

        return () => {
            unloadAsset(item._id, "thumb");
        };
    }, []);

    const isSelected = selectedItems.has(item._id);

    const { longPressHandlers } = useLongPress({
        onLongPress: () => {
            enableSelecting(true);
            addToMultipleSelection(item);
            setLastSelectedItemId(item._id);
        },
        onClick: (modifiers) => {
            if (modifiers.ctrlKey || modifiers.metaKey) {
                enableSelecting(true);
                if (isSelected) {
                    removeFromMultipleSelection(item);
                }
                else {
                    addToMultipleSelection(item);
                }
                setLastSelectedItemId(item._id);
            }
            else if (modifiers.shiftKey) {
                enableSelecting(true);
                if (lastSelectedItemId) {
                    selectRange(lastSelectedItemId, item._id);
                }
                else {
                    addToMultipleSelection(item);
                    setLastSelectedItemId(item._id);
                }
            }
            else {
                if (onClick) {
                    onClick();
                }
            }
        },
        delay: 500,
    });

    const isStarred = item.labels && Array.isArray(item.labels) && item.labels.includes("starred");
    const isFlagged = item.labels && Array.isArray(item.labels) && item.labels.includes("flagged");

    return (
        <div
            data-id="gallery-thumb"
            className={isNewArrival ? "group gallery-thumb-container gallery-thumb-arrived" : "group gallery-thumb-container"}
            style={{
                position: "absolute",
                left: `${x}px`,
                top: `${y}px`,
                width: `${width}px`,
                height: `${height}px`,
                overflow: "hidden",
                borderRadius: "var(--radius-photo)",
                backgroundColor: "var(--color-raised)",
            }}
            onMouseEnter={() => setIsHovered(true)}
            onMouseLeave={() => setIsHovered(false)}
            {...longPressHandlers}
            >
            {/* The photo's own dominant colour, shown until its thumbnail loads. */}
            {item.color
                && <div
                    style={{
                        position: "absolute",
                        left: `0px`,
                        top: `0px`,
                        width: `100%`,
                        height: `100%`,
                        backgroundColor: `rgb(${item.color[0]}, ${item.color[1]}, ${item.color[2]})`,
                    }}
                    >
                </div>
            }

            {microDataURL
                && <img
                    data-testid="gallery-thumb"
                    className="gallery-thumb"
                    src={microDataURL}
                    style={{
                        position: "absolute",
                        left: "0",
                        top: "0",
                        width: "100%",
                        height: "100%",
                        objectFit: "cover",
                    }}
                    />
            }

            {thumbObjectURL
                &&  <img
                    data-testid="gallery-thumb"
                    className="gallery-thumb fade-in-thumb"
                    src={thumbObjectURL}
                    style={{
                        position: "absolute",
                        left: "0",
                        top: "0",
                        width: "100%",
                        height: "100%",
                        objectFit: "cover",
                    }}
                    />
            }

            {/* Ring of the accent colour inside the edge of a selected photo. */}

            {isSelected
                && <span
                    aria-hidden={true}
                    style={{
                        position: "absolute",
                        inset: 0,
                        pointerEvents: "none",
                        borderRadius: "var(--radius-photo)",
                        boxShadow: "var(--photo-selected-ring)",
                    }}
                    />
            }

            {/* Selection tick mark. It shows under the pointer, and on every photo while a selection is open. */}

            <div
                data-id="gallery-item-checkbox"
                className={(isSelecting || isSelected) ? "flex" : "hidden group-hover:flex"}
                style={{
                    position: "absolute",
                    left: "var(--space-2)",
                    top: "var(--space-2)",
                    width: "var(--tile-tick-size)",
                    height: "var(--tile-tick-size)",
                    boxSizing: "border-box",
                    borderRadius: "var(--radius-tile-tick)",
                    backgroundColor: isSelected ? "var(--color-accent)" : "var(--color-tile-tick-fill)",
                    border: isSelected ? "2px solid var(--color-accent)" : "2px solid var(--color-tile-tick-ring)",
                    boxShadow: isSelected ? "none" : "var(--tile-tick-shadow)",
                    color: "var(--color-on-accent)",
                    justifyContent: "center",
                    alignItems: "center",
                    cursor: "pointer",
                    transition: "background-color var(--duration-fast) var(--ease-standard)",
                }}
                onMouseDown={event => event.stopPropagation()}
                onMouseUp={event => event.stopPropagation()}
                onClick={event => {
                    event.preventDefault();
                    event.stopPropagation();
                    if (event.shiftKey && lastSelectedItemId) {
                        selectRange(lastSelectedItemId, item._id);
                    }
                    else {
                        if (isSelected) {
                            removeFromMultipleSelection(item);
                        }
                        else {
                            addToMultipleSelection(item);
                            setLastSelectedItemId(item._id);
                        }
                    }
                }}
                >
                {isSelected
                    && <svg
                        xmlns="http://www.w3.org/2000/svg"
                        viewBox="0 0 24 24"
                        fill="currentColor"
                        style={{
                            width: "var(--icon-sm)",
                            height: "var(--icon-sm)",
                        }}
                        >
                        <path d="M9 16.17L4.83 12l-1.42 1.41L9 19 21 7l-1.41-1.41z" />
                    </svg>
                }
            </div>

            {item.contentType.startsWith("video")
                && <div
                    style={{
                        position: "absolute",
                        left: "50%",
                        top: "50%",
                        transform: "translate(-50%, -50%)",
                        width: "calc(var(--space-8) + var(--space-2))",
                        height: "calc(var(--space-8) + var(--space-2))",
                        borderRadius: "var(--radius-full)",
                        backgroundColor: "var(--color-video-badge-bg)",
                        color: "var(--gray-0)",
                        display: "var(--video-play-display)",
                        justifyContent: "center",
                        alignItems: "center",
                        cursor: "pointer",
                    }}
                    >
                    <svg
                        xmlns="http://www.w3.org/2000/svg"
                        viewBox="0 0 24 24"
                        fill="currentColor"
                        style={{
                            width: "var(--icon-lg)",
                            height: "var(--icon-lg)",
                        }}
                        >
                        <path d="M8 5v14l11-7z"/>
                    </svg>
                </div>
            }

            {/* Star toggle. */}

            {(isHovered || isStarred) &&
                <div
                    style={{
                        position: "absolute",
                        right: "var(--space-2)",
                        top: "var(--space-2)",
                        width: "calc(var(--icon-lg) + var(--space-1))",
                        height: "calc(var(--icon-lg) + var(--space-1))",
                        boxSizing: "border-box",
                        borderRadius: "var(--radius-full)",
                        backgroundColor: "var(--color-tile-star-fill)",
                        border: "2px solid var(--gray-0)",
                        color: isStarred ? "var(--color-tile-starred)" : "var(--color-tile-star-icon)",
                        display: "flex",
                        justifyContent: "center",
                        alignItems: "center",
                        cursor: "pointer",
                    }}
                    onMouseDown={event => event.stopPropagation()}
                    onMouseUp={event => event.stopPropagation()}
                    onClick={async (event) => {
                        event.preventDefault();
                        event.stopPropagation();
                        if (isStarred) {
                            await removeArrayValue(item._id, "labels", "starred");
                        }
                        else {
                            await addArrayValue(item._id, "labels", "starred");
                        }
                    }}
                    >
                    <svg
                        xmlns="http://www.w3.org/2000/svg"
                        viewBox="0 0 24 24"
                        fill="currentColor"
                        style={{
                            width: "var(--icon-sm)",
                            height: "var(--icon-sm)",
                        }}
                        >
                        <path d="M12 17.27L18.18 21l-1.64-7.03L22 9.24l-7.19-.61L12 2 9.19 8.63 2 9.24l5.46 4.73L5.82 21z"/>
                    </svg>
                </div>
            }

            {/* Flag toggle. */}

            {(isHovered || isFlagged) &&
                <div
                    style={{
                        position: "absolute",
                        right: "var(--space-2)",
                        bottom: "var(--space-2)",
                        width: "calc(var(--icon-lg) + var(--space-1))",
                        height: "calc(var(--icon-lg) + var(--space-1))",
                        boxSizing: "border-box",
                        borderRadius: "var(--radius-full)",
                        backgroundColor: "var(--color-tile-flag-fill)",
                        border: "2px solid var(--gray-0)",
                        color: isFlagged ? "var(--color-tile-flagged)" : "var(--color-tile-flag-icon)",
                        display: "flex",
                        justifyContent: "center",
                        alignItems: "center",
                        cursor: "pointer",
                    }}
                    onMouseDown={event => event.stopPropagation()}
                    onMouseUp={event => event.stopPropagation()}
                    onClick={async (event) => {
                        event.preventDefault();
                        event.stopPropagation();
                        if (isFlagged) {
                            await removeArrayValue(item._id, "labels", "flagged");
                        }
                        else {
                            await addArrayValue(item._id, "labels", "flagged");
                        }
                    }}
                    >
                    <svg
                        xmlns="http://www.w3.org/2000/svg"
                        viewBox="0 0 24 24"
                        fill="currentColor"
                        style={{
                            width: "var(--icon-sm)",
                            height: "var(--icon-sm)",
                        }}
                        >
                        <path d="M14.4 6L14 4H5v17h2v-7h5.6l.4 2h7V6z"/>
                    </svg>
                </div>
            }
        </div>
    );
};