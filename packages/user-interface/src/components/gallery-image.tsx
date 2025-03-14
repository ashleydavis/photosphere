import React, { useEffect, useState } from "react";
import { useGallery } from "../context/gallery-context";
import { IGalleryItem } from "../lib/gallery-item";
import { useLongPress } from "../lib/long-press";

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

    //
    // True if the scrollbar is being dragged.
    //
    isDragging: boolean;
}

//
// Renders an image for the gallery.
//
export function GalleryImage({ item, onClick, x, y, width, height, isDragging }: IGalleryImageProps) {
    const [microDataURL, setMicroDataURL] = useState<string | undefined>(item.micro != undefined ? `data:image/jpeg;base64,${item.micro}` : undefined);
    const [thumbObjectURL, setThumbObjectURL] = useState<string | undefined>(undefined);

    const { loadAsset, unloadAsset, addToMultipleSelection, removeFromMultipleSelection, selectedItems, isSelecting, enableSelecting } = useGallery();

    useEffect(() => {
        if (thumbObjectURL) {
            // Already loaded.
            return;
        }

        if (!isDragging) {       
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
                    console.error(`Failed to load asset: thumb:${item._id}`);
                    console.error(err);
                });
        }

        return () => {
            if (!isDragging) {
                unloadAsset(item._id, "thumb");
            }
        };
    }, [isDragging]);

    const isSelected = selectedItems.has(item._id);

    let orientation = 1;
    if (item.properties?.exif?.Orientation) {
        orientation = item.properties.exif.Orientation?.[0];        
    }
    else if (item.properties?.metadata?.Orientation) {
        orientation = item.properties.metadata.Orientation?.[0];
    }

    const { longPressHandlers } = useLongPress({
        onLongPress: () => {
            enableSelecting(true);
            addToMultipleSelection(item);
        },
        onClick: () => {
            if (onClick) {
                onClick();
            }
        },
        delay: 500,
    });

    return (
        <div
            className="gallery-thumb-container"
            style={{
                position: "absolute",
                left: `${x}px`,
                top: `${y}px`,
                width: `${width}px`,
                height: `${height}px`,
                overflow: "hidden",
            }}
            >
            {item.color
                && <div                    
                    style={{
                        position: "absolute",
                        left: `0px`,
                        top: `0px`,
                        width: `100%`,
                        height: `100%`,
                        opacity: "0.7",
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
                    {...longPressHandlers}
                    style={{
                        position: "absolute",
                        left: "0",
                        top: "0",
                        width: "100%",
                        height: "100%",
                        objectFit: "contain",
                        scale: "1.05", // A small tweak to make the image cover the space without gaps.
                        transformOrigin: "center",
                    }}
                    />
            }    

            {thumbObjectURL
                &&  <img 
                    data-testid="gallery-thumb"
                    className="gallery-thumb fade-in-thumb"
                    src={thumbObjectURL}
                    {...longPressHandlers}
                    style={{
                        position: "absolute",
                        left: "0",
                        top: "0",
                        width: "100%",
                        height: "100%",
                        objectFit: "contain",
                        scale: "1.05", // A small tweak to make the image cover the space without gaps.
                        transformOrigin: "center",
                    }}
                    />
            }    

            {/* Selection tick mark. */}

            <div
                className="selection-tick"
                style={{
                    position: "absolute",
                    left: "8px",
                    top: "8px",
                    width: "24px",
                    height: "24px",
                    borderRadius: "50%",
                    backgroundColor: isSelected ? "rgba(0, 0, 255, 1)" : "rgba(0, 0, 0, 0.25)",
                    justifyContent: "center",
                    alignItems: "center",
                    cursor: "pointer",
                    display: (isSelecting || isSelected) ? "flex" : undefined,
                }}
                onClick={event => {
                    event.preventDefault();
                    event.stopPropagation();
                    if (isSelected) {
                        removeFromMultipleSelection(item);
                    }
                    else {
                        addToMultipleSelection(item);
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

            {item.contentType.startsWith("video")
                && <div
                    {...longPressHandlers}
                    style={{
                        position: "absolute",
                        left: "50%",
                        top: "50%",
                        transform: "translate(-50%, -50%)",
                        width: "48px",
                        height: "48px",
                        borderRadius: "50%",
                        backgroundColor: "rgba(0, 0, 0, 0.5)",
                        display: "flex",
                        justifyContent: "center",
                        alignItems: "center",
                        cursor: "pointer",
                    }}
                    >
                    <svg
                        xmlns="http://www.w3.org/2000/svg"
                        viewBox="0 0 24 24"
                        fill="white"
                        width="32px"
                        height="32px"
                        >
                        <path d="M8 5v14l11-7z"/>
                    </svg>
                </div>
            }

            {/* Image number. */}

            {/* <div
                style={{
                    position: "absolute",
                    left: `8px`,
                    bottom: `8px`,
                    padding: "2px",
                    color: "white",
                    backgroundColor: "rgba(0, 0, 0, 0.5)",
                    pointerEvents: "none",
                    fontSize: "14px",
                    lineHeight: "14px",
                }}
                >
                #{item.searchIndex!+1}
            </div> */}

            {/* Renders a debug panel for each image showing it's position and dimensions. */}
            {/* <div
                style={{
                    position: "absolute",
                    right: `2px`,
                    bottom: `2px`,
                    color: "black",
                    backgroundColor: `rgba(255, 255, 255, 0.75)`,
                    border: "1px solid black",
                    padding: "3px",
                    pointerEvents: "none",
                    fontSize: "12px",
                    lineHeight: "14px",
                }}
                >
                <p>
                    {item.photoDate ? dayjs(item.photoDate).format("DD/MM/YYYY") : "No date"}
                </p>

                <p>
                    left = {x.toFixed(2)}  
                </p>
                <p>
                    top = {y.toFixed(2)}
                </p>
                <p>
                    right = {(x+width).toFixed(2)}  
                </p>
                <p>
                    bottom = {(y+height).toFixed(2)}
                </p>
                <p>
                    w = {width.toFixed(2)}
                </p>
                <p>
                    h = {height.toFixed(2)}
                </p>
            </div> */}
        </div>
    );
};