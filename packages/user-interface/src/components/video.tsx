import React, { useEffect, useState } from "react";
import { IGalleryItem } from "../lib/gallery-item";
import { useGallery } from "../context/gallery-context";

export interface IVideoProps {
    //
    // The asset being displayed.
    //
    asset: IGalleryItem;
}

//
// Renders an image.
//
export function Video({ asset }: IVideoProps) {

    const [objectURL, setObjectURL] = useState<string>("");

    const { loadAsset, unloadAsset } = useGallery();

    useEffect(() => {
        loadAsset(asset._id, "asset")
            .then(assetLoaded => {
                if (assetLoaded) {
                    setObjectURL(assetLoaded.objectUrl);
                }
            })
            .catch(err => {
                console.error(`Failed to load video asset: ${asset._id}`);
                console.error(err);
            });

        return () => {
            unloadAsset(asset._id, "asset");
        };
    }, [asset]);

    return (
        <>
            {objectURL
                && <video
                    className="w-full h-full"
                    muted={true}
                    autoPlay={true}
                    controls={true}
                    loop={true}
                    src={objectURL}
                    />
            }    
        </>
    );
};