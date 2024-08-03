import React, { useEffect, useState } from "react";
import { IGalleryItem } from "../lib/gallery-item";
import { useGallery } from "../context/gallery-context";
import { getImageTransform } from "../lib/image";

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
    assetType: string;
}

//
// Renders an image.
//
export function Image({ testId, imgClassName, asset, assetType }: IImageProps) {

    const [objectURL, setObjectURL] = useState<string>("");

    const { loadAsset, unloadAsset } = useGallery();

    useEffect(() => {
        loadAsset(asset._id, assetType)
            .then(assetLoaded => {
                if (assetLoaded) {
                    setObjectURL(assetLoaded.objectUrl);
                }
            })
            .catch(err => {
                console.error(`Failed to load asset: ${assetType}:${asset._id}`);
                console.error(err);
            });

        return () => {
            unloadAsset(asset._id, assetType);
        };
    }, [asset]);

    let orientation = 1;
    if (asset.properties?.exif?.Orientation) {
        orientation = asset.properties.exif.Orientation?.[0];        
    }
    else if (asset.properties?.metadata?.Orientation) {
        orientation = asset.properties.metadata.Orientation?.[0];
    }

    return (
        <>
            {objectURL
                && <img 
                    data-testid={testId}
                    className={imgClassName}
                    src={objectURL}
                    style={{
                        padding: "2px",
                        transform: getImageTransform(orientation, undefined),
                    }}
                    />
            }    
        </>
    );
};