import React, { useEffect, useState } from "react";
import { log } from "utils";
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
// The height of the film strip along the foot of the viewer: a thumbnail and the room above and
// below it. AssetView uses it too, to sit the quick info and Delete just above the strip.
//
export const FILM_STRIP_HEIGHT = "calc(var(--space-8) * 1.5 + var(--space-2) * 2)";

//
// Props for a single thumbnail in the film strip.
//
interface IFilmStripThumbProps {
    //
    // The gallery item the thumbnail shows.
    //
    item: IGalleryItem;

    //
    // True for the focused asset, which the strip marks with the accent ring.
    //
    isCurrent: boolean;

    //
    // Called when this thumbnail is clicked (undefined for the focused asset).
    //
    onClick: (() => void) | undefined;
}

//
// Renders one thumbnail of the film strip, marking the focused asset with the
// --film-strip-current-* tokens as the style guide's film strip does. It shows the item's micro
// thumbnail at once and the thumb image once it has loaded, so the strip is never a row of blanks
// for items that have no micro thumbnail.
//
function FilmStripThumb({ item, isCurrent, onClick }: IFilmStripThumbProps) {
    const { loadAsset, unloadAsset } = useGallery();
    const [thumbObjectURL, setThumbObjectURL] = useState<string | undefined>(undefined);

    useEffect(() => {
        loadAsset(item._id, "thumb")
            .then(assetLoaded => {
                if (assetLoaded) {
                    setThumbObjectURL(assetLoaded.objectUrl);
                }
            })
            .catch(err => {
                log.exception(`Failed to load asset: thumb:${item._id}`, err as Error);
            });

        return () => {
            unloadAsset(item._id, "thumb");
        };
    }, [item._id]);

    let imageURL = thumbObjectURL;
    if (!imageURL && item.micro) {
        imageURL = `data:image/jpeg;base64,${item.micro}`;
    }

    let width = "calc(var(--space-8) * 1.25)";
    let border = "1px solid var(--color-viewer-control-border)";
    let boxShadow = "none";
    let transform = "none";
    let className = "relative flex-none overflow-hidden cursor-pointer opacity-[var(--film-strip-other-opacity)] hover:opacity-100";
    if (isCurrent) {
        width = "var(--film-strip-current-width)";
        border = "var(--film-strip-current-border)";
        boxShadow = "var(--film-strip-current-ring)";
        transform = "translateY(var(--film-strip-current-lift))";
        className = "relative flex-none overflow-hidden";
    }

    return (
        <div
            onClick={onClick}
            className={className}
            style={{
                width,
                height: "calc(var(--space-8) * 1.5)",
                margin: "0 var(--space-1)",
                borderRadius: "var(--radius-sm)",
                border,
                boxShadow,
                transform,
                background: "var(--color-raised)",
                transition: "width var(--duration-normal) var(--ease-standard), opacity var(--duration-fast) var(--ease-standard)",
            }}
        >
            {imageURL
                ? <img
                    src={imageURL}
                    className="pointer-events-none h-full w-full"
                    style={{
                        objectFit: "cover",
                    }}
                  />
                : null
            }
        </div>
    );
}

//
// Shows the focused asset at full size, filling the space above the film strip, and a film strip
// along the foot with the assets either side of it, so a click on a thumbnail opens that asset.
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

    return (
        <>
            <div
                className="absolute inset-x-0 top-0 pointer-events-none"
                style={{
                    bottom: FILM_STRIP_HEIGHT,
                }}
            >
                {asset.contentType.startsWith("video/")
                    ? <Video key={asset._id} asset={asset} />
                    : <FullImage key={asset._id} asset={asset} />
                }
            </div>
            <div
                className="absolute inset-x-0 bottom-0 grid items-center"
                style={{
                    height: FILM_STRIP_HEIGHT,
                    gridTemplateColumns: "1fr auto 1fr",
                    padding: "var(--space-2) 0",
                }}
            >
                <div className="flex justify-end min-w-0 overflow-hidden">
                    {prevItems.map(({ item }) => (
                        <FilmStripThumb
                            key={item._id}
                            item={item}
                            isCurrent={false}
                            onClick={() => setSelectedItemId(item._id)}
                        />
                    ))}
                </div>
                <FilmStripThumb
                    item={asset}
                    isCurrent={true}
                    onClick={undefined}
                />
                <div className="flex justify-start min-w-0 overflow-hidden">
                    {nextItems.map(({ item }) => (
                        <FilmStripThumb
                            key={item._id}
                            item={item}
                            isCurrent={false}
                            onClick={() => setSelectedItemId(item._id)}
                        />
                    ))}
                </div>
            </div>
        </>
    );
}
