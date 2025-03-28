import React, { useEffect, useState } from "react";
import { IGalleryItem } from "../lib/gallery-item";
import { useGallery } from "../context/gallery-context";

export interface IImageProps {
    //
    // The asset being displayed.
    //
    asset: IGalleryItem;
}

//
// Renders an image.
//
export function FullImage({ asset }: IImageProps) {
    const [microDataURL, setMicroDataURL] = useState<string | undefined>(asset.micro != undefined ? `data:image/jpeg;base64,${asset.micro}` : undefined);
    const [thumbnailObjectURL, setThumbnailObjectURL] = useState<string | undefined>(undefined);
    const [objectURL, setObjectURL] = useState<string | undefined>(undefined);

    const { loadAsset, unloadAsset } = useGallery();

    useEffect(() => {
        loadAsset(asset._id, "thumb")
            .then(assetLoaded => {
                if (assetLoaded) {
                    setThumbnailObjectURL(assetLoaded.objectUrl);
                    setTimeout(() => {
                        setMicroDataURL(undefined);
                    }, 700);
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
                    }, 700);
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
    }, []);

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
                    src={microDataURL}
                    style={{
                        padding: "2px",
                        position: "absolute",
                        top: "0",
                        left: "0",
                        right: "0",
                        bottom: "0",
                        width: "80%",
                        height: "80%",
                        margin: "auto",
                        objectFit: "contain",
                    }}
                    />
            }
            
            {thumbnailObjectURL
                && <img
                    className="fade-in-thumb"
                    src={thumbnailObjectURL}
                    style={{
                        padding: "2px",
                        position: "absolute",
                        top: "0",
                        left: "0",
                        right: "0",
                        bottom: "0",
                        width: "80%",
                        height: "80%",
                        margin: "auto",
                        objectFit: "contain",
                    }}
                    />        
            }

            {objectURL
                && <img 
                    data-testid="fullsize-asset"
                    className="fade-in-thumb"
                    src={objectURL}
                    style={{
                        padding: "2px",
                        position: "absolute",
                        top: "0",
                        left: "0",
                        right: "0",
                        bottom: "0",
                        width: "80%",
                        height: "80%",
                        margin: "auto",
                        objectFit: "contain",
                    }}
                    />
            }    
        </>
    );
};