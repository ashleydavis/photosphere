import React from "react";
import { IGalleryItem } from "../lib/gallery-item";
import { useAssetDatabase } from "../context/asset-database-source";

export interface IVideoProps {
    //
    // The asset being displayed.
    //
    asset: IGalleryItem;
}

//
// Renders a video.
//
export function Video({ asset }: IVideoProps) {

    const { assetUrl } = useAssetDatabase();

    return (
        <video
            className="w-full h-full"
            muted={true}
            autoPlay={true}
            controls={true}
            loop={true}
            src={assetUrl(asset._id, "asset")}
            />
    );
};
