import React from "react";
import { IGalleryItem } from "../lib/gallery-item";
import { FullImage } from "./full-image";
import { Video } from "./video";
import { useGallery } from "../context/gallery-context";

//
// Props for the Carousel component.
//
export interface ICarouselProps {
    //
    // The currently focused asset shown at the centre of the carousel.
    //
    asset: IGalleryItem;
}

//
// Maximum number of items shown on each side of the focused asset.
//
const NUM_SIDE_ITEMS = 3;

//
// Horizontal offset from screen centre (in vw) for each slot distance index.
//
const SLOT_OFFSETS_VW = [0, 32, 45, 57];

//
// CSS scale factor for each slot distance index.
//
const SLOT_SCALES = [1, 0.38, 0.26, 0.18];

//
// Opacity for each slot distance index.
//
const SLOT_OPACITIES = [1, 0.88, 0.65, 0.42];

//
// Props for a single carousel item.
//
interface ICarouselItemProps {
    //
    // The gallery item to render in this slot.
    //
    item: IGalleryItem;

    //
    // Signed slot distance from centre: negative = left, positive = right, 0 = centre.
    //
    distance: number;

    //
    // Called when this item is clicked (undefined for the centre item).
    //
    onClick: (() => void) | undefined;
}

//
// A single positioned item within the carousel.
// Centre item renders the full FullImage/Video; side items render the micro thumbnail.
//
function CarouselItem({ item, distance, onClick }: ICarouselItemProps) {
    const absDistance = Math.abs(distance);
    const directionSign = distance < 0 ? -1 : 1;
    const offsetVw = SLOT_OFFSETS_VW[absDistance] ?? 75;
    const scale = SLOT_SCALES[absDistance] ?? 0.15;
    const opacity = SLOT_OPACITIES[absDistance] ?? 0.25;
    const isCenter = distance === 0;

    return (
        <div
            onClick={onClick}
            style={{
                position: "absolute",
                left: "50%",
                top: "50%",
                width: "100%",
                height: "100%",
                transform: `translate(-50%, -50%) translateX(${directionSign * offsetVw}vw) scale(${scale})`,
                opacity,
                transition: "transform 0.4s ease-in-out, opacity 0.4s ease-in-out",
                zIndex: 10 - absDistance,
                pointerEvents: isCenter ? "none" : "auto",
                cursor: isCenter ? "default" : "pointer",
            }}
        >
            {isCenter
                ? (item.contentType.startsWith("video/")
                    ? <Video key={item._id} asset={item} />
                    : <FullImage key={item._id} asset={item} />
                )
                : (item.micro
                    ? <img
                        src={`data:image/jpeg;base64,${item.micro}`}
                        style={{
                            position: "absolute",
                            top: 0,
                            left: 0,
                            right: 0,
                            bottom: 0,
                            width: "80%",
                            height: "80%",
                            margin: "auto",
                            objectFit: "contain",
                        }}
                      />
                    : null
                )
            }
        </div>
    );
}

//
// Horizontally arranged carousel showing the focused asset at full size in the centre,
// with surrounding assets tapering in scale and opacity on each side.
// All items animate smoothly into their new positions when navigation changes the focused asset.
//
export function Carousel({ asset }: ICarouselProps) {
    const { getPrev, getNext, setSelectedItemId } = useGallery();

    //
    // Build the list of previous items, nearest first, then reverse for left-to-right order.
    //
    const prevItems: Array<{ item: IGalleryItem; distance: number }> = [];
    let prevCurrent = asset;
    for (let distanceIdx = 1; distanceIdx <= NUM_SIDE_ITEMS; distanceIdx++) {
        const prev = getPrev(prevCurrent);
        if (!prev) {
            break;
        }
        prevItems.unshift({ item: prev, distance: -distanceIdx });
        prevCurrent = prev;
    }

    //
    // Build the list of next items, nearest first.
    //
    const nextItems: Array<{ item: IGalleryItem; distance: number }> = [];
    let nextCurrent = asset;
    for (let distanceIdx = 1; distanceIdx <= NUM_SIDE_ITEMS; distanceIdx++) {
        const next = getNext(nextCurrent);
        if (!next) {
            break;
        }
        nextItems.push({ item: next, distance: distanceIdx });
        nextCurrent = next;
    }

    const allItems = [
        ...prevItems,
        { item: asset, distance: 0 },
        ...nextItems,
    ];

    return (
        <>
            {allItems.map(({ item, distance }) => (
                <CarouselItem
                    key={item._id}
                    item={item}
                    distance={distance}
                    onClick={distance !== 0 ? () => setSelectedItemId(item._id) : undefined}
                />
            ))}
        </>
    );
}
