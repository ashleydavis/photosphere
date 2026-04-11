import React from "react";
import { IGalleryItem } from "../lib/gallery-item";
import { useGallery } from "../context/gallery-context";

//
// Props for the FilmStrip component.
//
export interface IFilmStripProps {
    //
    // The currently displayed asset.
    //
    asset: IGalleryItem;
}

//
// Number of items to show on each side of the current asset.
//
const NUM_SIDE_ITEMS = 3;

//
// Pixel sizes for items at distance 1, 2, and 3 from the current item.
//
const SIZES = [72, 54, 40];

//
// Opacity values for items at distance 1, 2, and 3 from the current item.
//
const OPACITIES = [0.88, 0.64, 0.40];

//
// Size of the current (center) item in the strip.
//
const CURRENT_SIZE = 84;

//
// Props for a single film frame.
//
interface IFilmFrameProps {
    //
    // The gallery item to display in this frame.
    //
    item: IGalleryItem;

    //
    // Absolute distance from the center (1 = adjacent, 2 = two away, 3 = three away).
    //
    absDistance: number;

    //
    // Called when the frame is clicked.
    //
    onClick: () => void;
}

//
// A single frame in the film strip.
//
function FilmFrame({ item, absDistance, onClick }: IFilmFrameProps) {
    const size = SIZES[absDistance - 1] ?? 30;
    const opacity = OPACITIES[absDistance - 1] ?? 0.25;
    const microUrl = item.micro ? `data:image/jpeg;base64,${item.micro}` : undefined;

    return (
        <div
            onClick={onClick}
            style={{
                flexShrink: 0,
                width: `${size}px`,
                height: `${size}px`,
                opacity,
                cursor: "pointer",
                border: "1.5px solid rgba(255, 255, 255, 0.5)",
                overflow: "hidden",
                backgroundColor: "#111",
                borderRadius: "2px",
            }}
        >
            {microUrl && (
                <img
                    src={microUrl}
                    style={{
                        width: "100%",
                        height: "100%",
                        objectFit: "cover",
                        display: "block",
                    }}
                />
            )}
        </div>
    );
}

//
// Displays a horizontal film strip showing the previous and next few photos,
// tapering in size and opacity as they recede from the current asset.
//
export function FilmStrip({ asset }: IFilmStripProps) {
    const { getPrev, getNext, setSelectedItemId } = useGallery();

    //
    // Builds an ordered array of previous items, nearest first.
    //
    function buildPrevItems(): IGalleryItem[] {
        const items: IGalleryItem[] = [];
        let current = asset;
        for (let i = 0; i < NUM_SIDE_ITEMS; i++) {
            const prev = getPrev(current);
            if (!prev) {
                break;
            }
            items.push(prev);
            current = prev;
        }
        return items;
    }

    //
    // Builds an ordered array of next items, nearest first.
    //
    function buildNextItems(): IGalleryItem[] {
        const items: IGalleryItem[] = [];
        let current = asset;
        for (let i = 0; i < NUM_SIDE_ITEMS; i++) {
            const next = getNext(current);
            if (!next) {
                break;
            }
            items.push(next);
            current = next;
        }
        return items;
    }

    // prevItems is [prev1, prev2, prev3] (nearest first), reversed to [prev3, prev2, prev1] for display.
    const prevItems = buildPrevItems().reverse();
    const nextItems = buildNextItems(); // [next1, next2, next3] (nearest last)

    if (prevItems.length === 0 && nextItems.length === 0) {
        return null;
    }

    const currentMicroUrl = asset.micro ? `data:image/jpeg;base64,${asset.micro}` : undefined;

    return (
        <div
            style={{
                position: "absolute",
                bottom: "14px",
                left: "50%",
                transform: "translateX(-50%)",
                display: "flex",
                flexDirection: "row",
                alignItems: "center",
                gap: "5px",
                pointerEvents: "auto",
                padding: "9px 12px",
                backgroundColor: "rgba(0, 0, 0, 0.52)",
                borderRadius: "6px",
                backdropFilter: "blur(6px)",
            }}
        >
            {/* Previous items — farthest on the left */}
            {prevItems.map((item, idx) => {
                const absDistance = prevItems.length - idx;
                return (
                    <FilmFrame
                        key={item._id}
                        item={item}
                        absDistance={absDistance}
                        onClick={() => setSelectedItemId(item._id)}
                    />
                );
            })}

            {/* Current item */}
            <div
                style={{
                    flexShrink: 0,
                    width: `${CURRENT_SIZE}px`,
                    height: `${CURRENT_SIZE}px`,
                    border: "2px solid rgba(255, 255, 255, 0.9)",
                    overflow: "hidden",
                    backgroundColor: "#111",
                    borderRadius: "2px",
                    boxShadow: "0 0 0 1px rgba(255, 255, 255, 0.2), 0 2px 10px rgba(0, 0, 0, 0.7)",
                }}
            >
                {currentMicroUrl && (
                    <img
                        src={currentMicroUrl}
                        style={{
                            width: "100%",
                            height: "100%",
                            objectFit: "cover",
                            display: "block",
                        }}
                    />
                )}
            </div>

            {/* Next items — farthest on the right */}
            {nextItems.map((item, idx) => {
                const absDistance = idx + 1;
                return (
                    <FilmFrame
                        key={item._id}
                        item={item}
                        absDistance={absDistance}
                        onClick={() => setSelectedItemId(item._id)}
                    />
                );
            })}
        </div>
    );
}
