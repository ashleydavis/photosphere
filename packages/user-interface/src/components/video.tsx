import React, { useEffect, useState } from "react";
import { IGalleryItem } from "../lib/gallery-item";
import { useApi } from "../context/api-context";
import { useApp } from "../context/app-context";
import { useAssetDatabase } from "../context/asset-database-source";

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

    const { setId } = useAssetDatabase(); //TODO: This should not depend on the set! Otherwise we can't view videos from the local file system.
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
                    muted={true}
                    autoPlay={true}
                    controls={true}
                    loop={true}
                    src={assetUrl}
                    />
            }    
        </>
    );
};