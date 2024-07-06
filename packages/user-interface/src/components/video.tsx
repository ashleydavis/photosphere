import React, { useEffect, useState } from "react";
import { IGalleryItem } from "../lib/gallery-item";
import { useApi } from "../context/api-context";
import { useApp } from "../context/app-context";

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

    const { setId } = useApp();
    const { makeAssetUrl } = useApi();
    const [assetUrl, setAssetUrl] = useState<string>("");

    useEffect(() => {
        if (!setId) {
            return;
        }

        makeAssetUrl(setId, asset._id, "asset")
            .then(url => {
                setAssetUrl(url);
            })
            .catch(err => {
                console.error(`Failed to make asset url for video: ${asset._id}`);
                console.error(err);
            });
    }, [asset, setId]);

    return (
        <>
            {assetUrl
                && <video
                    className="w-full h-full"
                    autoPlay={true}
                    controls={true}
                    loop={true}
                    src={assetUrl}
                    />
            }    
        </>
    );
};