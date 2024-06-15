import React, { useEffect, useState } from "react";
import { useGallery } from "../context/gallery-context";
import { IGalleryItem } from "../lib/gallery-item";
import classNames from "classnames";

export interface IGalleryImageProps {
    //
    // The gallery item to render.
    //
    item: IGalleryItem;

    //
    // The global index of the gallery item.
    //
    itemIndex: number;

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
export function GalleryImage({ item, itemIndex, onClick, x, y, width, height }: IGalleryImageProps) {

    const [source, setSource] = useState<string>();
    const [objectURL, setObjectURL] = useState<string>("");

    const { loadAsset, unloadAsset } = useGallery();

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
            <div
                style={{
                    position: "absolute",
                    left: `${x}px`,
                    top: `${y}px`,
                    width: `${width}px`,
                    height: `${height}px`,                    
                    padding: "2px",
                }}
                >
                <div 
                    style={{ 
                        backgroundColor: "#E7E9ED", 
                        width: "100%", 
                        height: "100%" 
                    }}
                    >
                </div>
            </div>
            
            {objectURL
                && <img 
                    data-testid="gallery-thumb"
                    className={classNames("gallery-thumb", { "fade-in": source === "cloud" })}                    
                    src={objectURL}
                    style={{
                        position: "absolute",
                        left: `${x}px`,
                        top: `${y}px`,
                        width: `${width}px`,
                        height: `${height}px`,
                        padding: "2px",
                        // border: "1px solid red",
                    }}
                    onClick={() => {
                        if (onClick) {
                            onClick();
                        }
                    }}
                    />
            }    

            <div
                style={{
                    position: "absolute",
                    left: `${x}px`,
                    top: `${y}px`,
                    margin: "2px",
                    padding: "2px",
                    color: "white",
                    backgroundColor: "black",
                    pointerEvents: "none",
                    fontSize: "12px",
                    lineHeight: "14px",
                }}
                >
                #{itemIndex+1}
            </div>

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