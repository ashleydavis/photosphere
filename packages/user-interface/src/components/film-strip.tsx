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
// Frame sizes (px) for items at distance 1, 2, and 3 from the current item.
//
const SIZES = [84, 62, 46];

//
// Opacity values for items at distance 1, 2, and 3 from the current item.
//
const OPACITIES = [0.88, 0.64, 0.40];

//
// Gap between frames within each cluster, in pixels.
//
const FRAME_GAP = 5;

//
// Padding inside each cluster container, in pixels.
//
const CLUSTER_PADDING = 5;

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
    const size = SIZES[absDistance - 1] ?? 32;
    const opacity = OPACITIES[absDistance - 1] ?? 0.22;
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
                pointerEvents: "auto",
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
// Displays film strip frames on the left and right sides of the screen, vertically
// centred, so the full-screen photo feels like the centre frame of a film strip.
// Frames taper in size and opacity as they recede from the current asset.
// Cluster positions track the rendered photo edges so there is no gap for portrait photos.
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

    // [prev1, prev2, prev3] — nearest first; reversed to [prev3, prev2, prev1] for display.
    const prevItems = buildPrevItems();
    const nextItems = buildNextItems(); // [next1, next2, next3]

    //
    // Common styles for each side container.
    //
    const sideContainerStyle: React.CSSProperties = {
        position: "absolute",
        top: "50%",
        transform: "translateY(-50%)",
        display: "flex",
        flexDirection: "row",
        alignItems: "center",
        gap: `${FRAME_GAP}px`,
        padding: `${CLUSTER_PADDING}px`,
        pointerEvents: "none",
    };

    return (
        <>
            {/* Left side: farthest frame on the left, nearest on the right */}
            {prevItems.length > 0 && (
                <div style={{ ...sideContainerStyle, left: 0 }}>
                    {[...prevItems].reverse().map((item, idx) => {
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
                </div>
            )}

            {/* Right side: nearest frame on the left, farthest on the right */}
            {nextItems.length > 0 && (
                <div style={{ ...sideContainerStyle, right: 0 }}>
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
            )}
        </>
    );
}
