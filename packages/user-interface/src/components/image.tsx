import React, { useEffect, useState } from "react";
import { IGalleryItem } from "../lib/gallery-item";
import { useGallery } from "../context/gallery-context";
import { getImageTransform } from "../lib/image";

export interface IImageProps {
    //
    // The asset being displayed.
    //
    asset: IGalleryItem;
}

//
// Renders an image.
//
export function Image({ asset }: IImageProps) {

    const [thumbnailObjectURL, setThumbnailObjectURL] = useState<string | undefined>(undefined);
    const [objectURL, setObjectURL] = useState<string | undefined>(undefined);

    const { loadAsset, unloadAsset } = useGallery();

    useEffect(() => {
        loadAsset(asset._id, "thumb")
            .then(assetLoaded => {
                if (assetLoaded) {
                    setThumbnailObjectURL(assetLoaded.objectUrl);
                }
            })
            .catch(err => {
                console.error(`Failed to load asset: thumb:${asset._id}`);
                console.error(err);
            });

        loadAsset(asset._id, "display")
            .then(assetLoaded => {
                if (assetLoaded) {
                    setObjectURL(assetLoaded.objectUrl);
                    setThumbnailObjectURL(undefined);
                }
            })
            .catch(err => {
                console.error(`Failed to load asset: display:${asset._id}`);
                console.error(err);
            });

        return () => {
            unloadAsset(asset._id, "thumb");
            unloadAsset(asset._id, "display");
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
            {thumbnailObjectURL
                && <img
                    className="thumbnail"
                    src={thumbnailObjectURL}
                    style={{
                        padding: "2px",
                        transform: getImageTransform(orientation, undefined),
                    }}
                    />        
            }
            {objectURL
                && <img 
                    data-testid="fullsize-asset"
                    className="full fade-in"
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