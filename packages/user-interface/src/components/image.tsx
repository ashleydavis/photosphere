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

    const { source } = useGallery();

    useEffect(() => {
        source.loadAsset(asset._id, type, objectURL => {
            setObjectURL(objectURL);
        });

        return () => {
            source.unloadAsset(asset._id, type);
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