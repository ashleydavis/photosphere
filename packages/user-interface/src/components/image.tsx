import React, { useEffect, useState } from "react";
import { IGalleryItem } from "../lib/gallery-item";
import { useGallery } from "../context/gallery-context";

export interface IImageProps {
    //
    // Test ID for the image attribute.
    //
    testId?: string;

    //
    // Class name for the image attribute.
    //
    imgClassName?: string;

    //
    // The asset being displayed.
    //
    asset: IGalleryItem;

    //
    // The type of asset to retreive.
    //
    type: string;

    //
    // Event raised when an item in the gallery has been clicked.
    //
    onClick?: (() => void);
}

//
// Renders an image.
//
export function Image({ testId, imgClassName, asset, type, onClick }: IImageProps) {

    const [objectURL, setObjectURL] = useState<string>("");

    const { loadAsset, unloadAsset } = useGallery();

    useEffect(() => {
        loadAsset(asset._id, type)
            .then(objectURL => {
                if (objectURL) {
                    setObjectURL(objectURL);
                }
            })
            .catch(err => {
                console.error("Failed to load asset: ${type}:${asset._id}");
                console.error(err);
            });

        return () => {
            unloadAsset(asset._id, type);
        };
    }, [asset]);

    return (
        <>
            {objectURL
                && <img 
                    data-testid={testId}
                    className={imgClassName}
                    src={objectURL}
                    style={{
                        padding: "2px",
                    }}
                    onClick={() => {
                        if (onClick) {
                            onClick();
                        }
                    }}
                    />
            }    
        </>
    );
};