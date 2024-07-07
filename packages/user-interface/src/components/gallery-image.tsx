import React, { useEffect, useState } from "react";
import { useGallery } from "../context/gallery-context";
import { IGalleryItem } from "../lib/gallery-item";
import classNames from "classnames";
import { getImageTransform } from "../lib/image";

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

    const [source, setSource] = useState<string>();
    const [objectURL, setObjectURL] = useState<string>("");

    const { loadAsset, unloadAsset, addToMultipleSelection, removeFromMultipleSelection } = useGallery();

    const gutter = 1;

    useEffect(() => {
        loadAsset(item._id, "thumb")
            .then(assetLoaded => {
                if (assetLoaded) {
                    setSource(assetLoaded.source);
                    setObjectURL(assetLoaded.objectUrl);
                }
            })
            .catch(err => {
                console.error(`Failed to load asset: thumb:${item._id}`);
                console.error(err);
            });

        return () => {
            unloadAsset(item._id, "thumb");
        };
    }, [item]);

    return (
        <>
            {objectURL
                && <div
                    style={{
                        position: "absolute",
                        left: `${x}px`,
                        top: `${y}px`,
                        width: `${width-gutter}px`,
                        height: `${height-gutter}px`,
                        overflow: "hidden",
                        // border: "1px solid red",
                    }}
                    >
                    <img 
                        data-testid="gallery-thumb"
                        className={classNames("gallery-thumb", { "fade-in": source === "cloud" })}                    
                        src={objectURL}
                        style={{
                            position: "absolute",
                            left: "0",
                            top: "0",
                            width: "100%",
                            height: "100%",
                            objectFit: "contain",
                            transform: getImageTransform(item.properties?.exif?.Orientation?.[0], item.aspectRatio),
                            transformOrigin: "center",
                        }}
                        onClick={() => {
                            if (onClick) {
                                onClick();
                            }
                        }}
                        />

                    {item.contentType.startsWith("video")
                        && <div
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
                            onClick={() => {
                                if (onClick) {
                                    onClick();
                                }
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

                    {/* Selection tick mark. */}

                    <div
                        style={{
                            position: "absolute",
                            left: "8px",
                            top: "8px",
                            width: "24px",
                            height: "24px",
                            borderRadius: "50%",
                            backgroundColor: item.selected ? "rgba(0, 0, 255, 1)" : "rgba(0, 0, 0, 0.25)",
                            display: "flex",
                            justifyContent: "center",
                            alignItems: "center",
                            cursor: "pointer",
                        }}
                        onClick={async event => {
                            event.preventDefault();
                            event.stopPropagation();
                            if (item.selected) {
                                await removeFromMultipleSelection(item);
                            }
                            else {
                                await addToMultipleSelection(item);
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

                    {/* Image number. */}

                    <div
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
                    </div>
                </div>
            }    

            {/* Renders a debug panel for each image showing it's position and dimensions. */}
            {/* <div
                style={{
                    position: "absolute",
                    left: `${x+2}px`,
                    top: `${y+30}px`,
                    color: "black",
                    backgroundColor: "white",
                    border: "1px solid black",
                    padding: "8px",
                    paddingRight: "12px",
                    pointerEvents: "none",
                    fontSize: "12px",
                    lineHeight: "14px",
                }}
                >
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
        </>
    );
};