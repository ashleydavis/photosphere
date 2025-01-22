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

    const [microDataURL, setMicroDataURL] = useState<string | undefined>(undefined);
    const [thumbnailObjectURL, setThumbnailObjectURL] = useState<string | undefined>(undefined);
    const [objectURL, setObjectURL] = useState<string | undefined>(undefined);

    const { loadAsset, unloadAsset } = useGallery();

    useEffect(() => {
        if (thumbnailObjectURL) {
            // Already loaded.
            return;
        }

        if (asset.micro) {
            setMicroDataURL(`data:image/jpeg;base64,${asset.micro}`);
        }

        loadAsset(asset._id, "thumb")
            .then(assetLoaded => {
                if (assetLoaded) {
                    setThumbnailObjectURL(assetLoaded.objectUrl);
                    setTimeout(() => {
                        setMicroDataURL(undefined);
                    }, 1200);
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
                    setTimeout(() => {
                        setThumbnailObjectURL(undefined);
                    }, 600);
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
            {microDataURL
                && <img 
                    className="micro"
                    src={microDataURL}
                    style={{
                        padding: "2px",
                        transform: getImageTransform(orientation, undefined),
                    }}
                    />
            }
            
            {thumbnailObjectURL
                && <img
                    className="thumbnail fade-in"
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